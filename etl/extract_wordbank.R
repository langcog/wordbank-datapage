#!/usr/bin/env Rscript
# Extract the wordbank MySQL database into tidy parquet tables (data/) for
# upload to Redivis. Table shapes mirror wordbankr return values so that a
# future wordbankr can point at Redivis without API changes.
#
# Usage:
#   Rscript etl/extract_wordbank.R          # full extraction (~89 instruments)
#   Rscript etl/extract_wordbank.R --test   # a few small instruments only
#
# Per-instrument response pulls are resumable: existing parquet files in
# data/item_responses/ are skipped, so a crashed run can just be restarted.

suppressMessages({
  library(wordbankr)
  library(dplyr)
  library(tidyr)
  library(purrr)
  library(stringr)
  library(arrow)
})

test_mode <- "--test" %in% commandArgs(trailingOnly = TRUE)
test_instruments <- c("Kiswahili WG", "Kiswahili WS", "English (American) WGShort")

out_dir <- "data"
resp_dir <- file.path(out_dir, "item_responses")
dir.create(resp_dir, recursive = TRUE, showWarnings = FALSE)

san <- function(x) x |> str_to_lower() |> str_replace_all("[^a-z0-9]+", "_") |>
  str_replace_all("^_|_$", "")

retry <- function(expr, tries = 3, label = "") {
  for (i in seq_len(tries)) {
    result <- tryCatch(expr, error = function(e) {
      message(sprintf("  attempt %d/%d failed for %s: %s", i, tries, label,
                      conditionMessage(e)))
      NULL
    })
    if (!is.null(result)) return(result)
    Sys.sleep(5 * i)
  }
  stop("giving up on ", label)
}

# ---- core tables -----------------------------------------------------------

message("pulling core tables...")
instruments <- retry(get_instruments(), label = "instruments")
datasets <- retry(get_datasets(admin_data = TRUE), label = "datasets")
items <- retry(get_item_data(), label = "items")
# filter_age = FALSE: the canonical table keeps administrations outside the
# instrument's normed age range (the wordbankr default drops them); the
# in_age_range flag lets consumers apply the usual filter
admins_full <- retry(
  get_administration_data(filter_age = FALSE,
                          include_demographic_info = TRUE,
                          include_birth_info = TRUE,
                          include_health_conditions = TRUE,
                          include_language_exposure = TRUE),
  label = "administrations")
admins_full <- admins_full |>
  left_join(instruments |> select(language, form, age_min, age_max),
            by = c("language", "form")) |>
  mutate(in_age_range = !is.na(age) & age >= age_min & age <= age_max) |>
  select(-age_min, -age_max)

language_exposures <- admins_full |>
  select(data_id, exposures = language_exposures) |>
  filter(!map_lgl(exposures, is.null)) |>
  unnest(exposures)

health_conditions <- admins_full |>
  select(child_id, conditions = health_conditions) |>
  filter(!map_lgl(conditions, is.null)) |>
  unnest(conditions) |>
  distinct()

administrations <- admins_full |>
  select(-language_exposures, -health_conditions)

child_cols <- c("child_id", "dataset_origin_name", "birth_order",
                "caregiver_education", "ethnicity", "race", "sex",
                "birth_weight", "born_early_or_late", "gestational_age",
                "zygosity")
children <- administrations |>
  select(any_of(child_cols)) |>
  distinct(child_id, .keep_all = TRUE)
n_dup <- n_distinct(administrations$child_id) - nrow(children)
if (n_dup != 0) message("note: ", n_dup, " children had varying demographic rows")

write_parquet(instruments, file.path(out_dir, "instruments.parquet"))
write_parquet(datasets, file.path(out_dir, "datasets.parquet"))
write_parquet(items, file.path(out_dir, "items.parquet"))
write_parquet(administrations, file.path(out_dir, "administrations.parquet"))
write_parquet(children, file.path(out_dir, "children.parquet"))
write_parquet(language_exposures, file.path(out_dir, "language_exposures.parquet"))
write_parquet(health_conditions, file.path(out_dir, "health_conditions.parquet"))
message("core tables written: ",
        nrow(administrations), " administrations, ",
        nrow(children), " children, ", nrow(items), " items")

# ---- per-instrument item responses -----------------------------------------

insts <- instruments
if (test_mode) {
  insts <- insts |> filter(paste(language, form) %in% test_instruments)
  message("TEST MODE: ", nrow(insts), " instruments")
}

for (i in seq_len(nrow(insts))) {
  inst <- insts[i, ]
  slug <- san(paste(inst$language, inst$form))
  path <- file.path(resp_dir, paste0(slug, ".parquet"))
  if (file.exists(path)) next
  message(sprintf("[%d/%d] %s %s", i, nrow(insts), inst$language, inst$form))
  resp <- retry(
    get_instrument_data(language = inst$language, form = inst$form),
    label = slug)
  resp <- resp |>
    transmute(instrument_id = inst$instrument_id,
              language = inst$language, form = inst$form,
              data_id, item_id,
              value = na_if(value, ""),
              produces = coalesce(produces, FALSE),
              understands = coalesce(understands, FALSE))
  write_parquet(resp, path)
}

# ---- derived tables ---------------------------------------------------------
# Aggregated per instrument from the response parquets; combining across
# instruments uses summed counts so nothing large is held in memory at once.

message("computing derived tables...")
admin_ages <- administrations |> filter(in_age_range) |> select(data_id, age)
item_meta <- items |>
  select(language, form, item_id, item_kind, item_definition, category,
         lexical_category, uni_lemma)

resp_files <- list.files(resp_dir, full.names = TRUE)

per_inst <- map(resp_files, function(f) {
  resp <- read_parquet(f) |>
    inner_join(admin_ages, by = "data_id") |>
    filter(!is.na(age))

  item_summary <- resp |>
    left_join(item_meta, by = c("language", "form", "item_id")) |>
    group_by(instrument_id, language, form, item_id, item_kind,
             item_definition, category, lexical_category, uni_lemma, age) |>
    summarise(n_children = n_distinct(data_id),
              produces = mean(produces),
              understands = mean(understands),
              .groups = "drop")

  # counts (not proportions) so uni-lemma proportions pool correctly across
  # instruments within a language, mirroring uni_lemmas/print_all_prop_data.R
  uni_counts <- resp |>
    left_join(item_meta, by = c("language", "form", "item_id")) |>
    filter(!is.na(uni_lemma)) |>
    group_by(language, uni_lemma, age) |>
    summarise(words = paste(unique(unlist(strsplit(item_definition, ", "))),
                            collapse = ", "),
              produces = sum(produces),
              understands = sum(understands),
              n_responses = n(),
              n_children = n_distinct(data_id),
              .groups = "drop")

  list(item_summary = item_summary, uni_counts = uni_counts)
})

item_summaries <- map(per_inst, "item_summary") |>
  list_rbind() |>
  pivot_longer(c(produces, understands),
               names_to = "measure", values_to = "prop")
write_parquet(item_summaries, file.path(out_dir, "item_summaries.parquet"))

uni_lemma_summaries <- map(per_inst, "uni_counts") |>
  list_rbind() |>
  group_by(language, uni_lemma, age) |>
  summarise(words = paste(unique(unlist(strsplit(words, ", "))), collapse = ", "),
            produces = sum(produces) / sum(n_responses),
            understands = sum(understands) / sum(n_responses),
            n = sum(n_children),
            .groups = "drop") |>
  pivot_longer(c(produces, understands),
               names_to = "measure", values_to = "prop") |>
  group_by(uni_lemma) |>
  filter(n_distinct(language) > 1) |>
  ungroup()
write_parquet(uni_lemma_summaries, file.path(out_dir, "uni_lemma_summaries.parquet"))

quantile_probs <- c(0.10, 0.25, 0.50, 0.75, 0.90)
vocab_summaries <- administrations |>
  filter(in_age_range) |>
  select(language, form, form_type, age, production, comprehension) |>
  pivot_longer(c(production, comprehension),
               names_to = "measure", values_to = "vocab") |>
  filter(!is.na(vocab)) |>
  group_by(language, form, form_type, measure, age) |>
  reframe(n_children = n(),
          quantile = quantile_probs,
          vocab = quantile(vocab, quantile_probs, type = 7))
write_parquet(vocab_summaries, file.path(out_dir, "vocab_summaries.parquet"))

message("done. tables in ", out_dir, ":")
for (f in list.files(out_dir, pattern = "\\.parquet$")) {
  message("  ", f, ": ", nrow(read_parquet(file.path(out_dir, f))), " rows")
}
message("  item_responses/: ", length(resp_files), " instruments, ",
        sum(map_int(resp_files, ~nrow(read_parquet(.x)))), " rows total")
