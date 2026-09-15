#!/usr/bin/env Rscript
# Compute the derived tables from the core parquet tables in data/ and the
# per-instrument response files in data/item_responses/:
#   item_summaries, uni_lemma_summaries, vocab_summaries
# Runs after extract_wordbank.R (MySQL) or after fetch_redivis_tables.R --all +
# fetch_item_responses.R (Redivis), so a data release's derived tables can be
# rebuilt from either source. Aggregates per instrument, combining across
# instruments with summed counts so nothing large is held in memory at once.

suppressMessages({
  library(dplyr)
  library(tidyr)
  library(purrr)
  library(arrow)
})

out_dir <- "data"
resp_dir <- file.path(out_dir, "item_responses")

administrations <- read_parquet(file.path(out_dir, "administrations.parquet"))
items <- read_parquet(file.path(out_dir, "items.parquet"))
# form_type lives in instruments in the normalized (v2.0+) schema
if (!"form_type" %in% names(administrations)) {
  administrations <- administrations |>
    left_join(read_parquet(file.path(out_dir, "instruments.parquet")) |>
                select(language, form, form_type),
              by = c("language", "form"))
}

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
              produces = mean(produces, na.rm = TRUE),
              understands = mean(understands, na.rm = TRUE),
              .groups = "drop")

  # counts (not proportions) so uni-lemma proportions pool correctly across
  # instruments within a language, mirroring uni_lemmas/print_all_prop_data.R
  uni_counts <- resp |>
    left_join(item_meta, by = c("language", "form", "item_id")) |>
    filter(!is.na(uni_lemma)) |>
    group_by(language, uni_lemma, age) |>
    summarise(words = paste(unique(unlist(strsplit(item_definition, ", "))),
                            collapse = ", "),
              produces = sum(produces, na.rm = TRUE),
              understands = sum(understands, na.rm = TRUE),
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
          vocab = round(quantile(vocab, quantile_probs, type = 7), 2))
write_parquet(vocab_summaries, file.path(out_dir, "vocab_summaries.parquet"))

message("done: item_summaries ", nrow(item_summaries), " rows; uni_lemma_summaries ",
        nrow(uni_lemma_summaries), " rows; vocab_summaries ", nrow(vocab_summaries),
        " rows (from ", length(resp_files), " instruments)")
