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
datasets <- retry(get_datasets(admin_data = TRUE), label = "datasets") |>
  mutate(n_admins = as.integer(n_admins))
items <- retry(get_item_data(), label = "items") |>
  mutate(item_id = str_replace(item_id, "^Item_", "item_"))
# filter_age = FALSE: the canonical table keeps administrations outside the
# instrument's normed age range (the wordbankr default drops them); the
# in_age_range flag lets consumers apply the usual filter
admins_full <- retry(
  get_administration_data(filter_age = FALSE,
                          include_study_internal_id = TRUE,
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

# WS-type forms mostly do not measure comprehension: the import mirrors
# production into comprehension (langcog/wordbank#333). NA comprehension for
# datasets where every non-missing value equals production (the artifact
# signature), preserving the few WS datasets that genuinely collected it.
admins_full <- admins_full |>
  group_by(language, form, dataset_name) |>
  mutate(comprehension = if (first(form_type) == "WS" &&
                             any(!is.na(comprehension)) &&
                             all(comprehension == production, na.rm = TRUE)) {
    NA_integer_
  } else comprehension) |>
  ungroup()
message("WS comprehension mirroring: ",
        sum(admins_full$form_type == "WS" & is.na(admins_full$comprehension)),
        " WS rows now NA comprehension")

language_exposures <- admins_full |>
  select(data_id, exposures = language_exposures) |>
  filter(!map_lgl(exposures, is.null)) |>
  unnest(exposures) |>
  rename(exposure_percentage = exposure_proportion) |>
  # data quality (langcog/wordbank#334): values outside [0, 100] -> NA;
  # rows with no usable language are dropped; stray casing normalized
  mutate(exposure_out_of_range = !is.na(exposure_percentage) &
           (exposure_percentage < 0 | exposure_percentage > 100),
         exposure_percentage = ifelse(exposure_out_of_range, NA_real_,
                                      exposure_percentage),
         language = str_trim(language),
         language = if_else(str_detect(language, "^[a-z]"),
                            str_to_title(language), language))
if (any(language_exposures$exposure_out_of_range)) {
  message("note: ", sum(language_exposures$exposure_out_of_range),
          " language_exposure rows had out-of-range percentages, set to NA")
}
n_bad_lang <- sum(is.na(language_exposures$language) |
                  language_exposures$language %in% c("", "NA"))
if (n_bad_lang > 0) {
  message("note: dropped ", n_bad_lang,
          " language_exposure rows with missing/invalid language")
  language_exposures <- language_exposures |>
    filter(!is.na(language), !language %in% c("", "NA"))
}
language_exposures <- select(language_exposures, -exposure_out_of_range)

health_conditions <- admins_full |>
  select(child_id, conditions = health_conditions) |>
  filter(!map_lgl(conditions, is.null)) |>
  unnest(conditions) |>
  distinct()
n_unnamed <- sum(is.na(health_conditions$health_condition_name) |
                 health_conditions$health_condition_name == "")
if (n_unnamed > 0) {
  message("note: dropped ", n_unnamed, " unnamed health_condition rows")
  health_conditions <- health_conditions |>
    filter(!is.na(health_condition_name), health_condition_name != "")
}

# normalized schema: child-level variables live ONLY in children;
# administrations carries administration-level facts plus join keys
# (instrument-level form_type lives in instruments; dataset_origin_name in
# datasets/children)
child_cols <- c("child_id", "study_internal_id", "dataset_origin_name",
                "birth_order", "caregiver_education", "ethnicity", "race",
                "sex", "birth_weight", "born_early_or_late",
                "gestational_age", "zygosity")
children <- admins_full |>
  select(any_of(child_cols)) |>
  distinct(child_id, .keep_all = TRUE)
n_dup <- n_distinct(admins_full$child_id) - nrow(children)
if (n_dup != 0) message("note: ", n_dup, " children had varying demographic rows")

administrations <- admins_full |>
  transmute(data_id = as.integer(data_id),
            child_id = as.integer(child_id),
            dataset_name, language, form,
            age, date_of_test = as.Date(date_of_test),
            comprehension, production, is_norming, in_age_range)

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
  # store value/produces/understands exactly as the wordbankr API returns
  # them: "" (asked, negative) is distinct from NA (missing), and
  # produces/understands are NA for items/forms where they are undefined
  resp <- resp |>
    transmute(instrument_id = as.integer(inst$instrument_id),
              language = inst$language, form = inst$form,
              data_id = as.integer(data_id),
              item_id = str_replace(item_id, "^Item_", "item_"),
              value, produces, understands)
  write_parquet(resp, path)
}

# ---- derived tables ---------------------------------------------------------
# item_summaries, uni_lemma_summaries, vocab_summaries; reads the parquet
# tables written above (shared with the Redivis-sourced rebuild path)

source("etl/compute_derived.R")
resp_files <- list.files(resp_dir, full.names = TRUE)

message("done. tables in ", out_dir, ":")
for (f in list.files(out_dir, pattern = "\\.parquet$")) {
  message("  ", f, ": ", nrow(read_parquet(file.path(out_dir, f))), " rows")
}
message("  item_responses/: ", length(resp_files), " instruments, ",
        sum(map_int(resp_files, ~nrow(read_parquet(.x)))), " rows total")
