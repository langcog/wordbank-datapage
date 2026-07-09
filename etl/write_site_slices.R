#!/usr/bin/env Rscript
# Write per-selection data slices for the site from the extracted tables in
# data/. These are fetched lazily by the browser when a user picks an
# instrument (trajectories) or uni-lemma (crossling) — the tables are too big
# to embed in the page wholesale.
#
# Output:
#   slices/items/<language_form>.csv   item_summaries for one instrument
#   slices/unilemmas/<uni_lemma>.csv   uni_lemma_summaries for one uni-lemma
#   slices/unilemmas/index.json        available uni-lemmas + language counts
#   slices/admins/<language_form>.csv  administrations (with demographics) for
#                                      one instrument, for client-side norms

suppressMessages({
  library(arrow)
  library(dplyr)
  library(stringr)
  library(readr)
  library(purrr)
  library(jsonlite)
})

san <- function(x) x |> str_to_lower() |> str_replace_all("[^a-z0-9]+", "_") |>
  str_replace_all("^_|_$", "")

dir.create("slices/items", recursive = TRUE, showWarnings = FALSE)
dir.create("slices/unilemmas", recursive = TRUE, showWarnings = FALSE)

item_summaries <- read_parquet("data/item_summaries.parquet") |>
  filter(item_kind == "word") |>
  mutate(prop = round(prop, 4))

item_summaries |>
  group_by(language, form) |>
  group_walk(function(d, key) {
    d |>
      select(item_id, item_definition, category, age, n_children, measure, prop) |>
      write_csv(file.path("slices/items",
                          paste0(san(paste(key$language, key$form)), ".csv")))
  })
message("wrote ", length(list.files("slices/items")), " instrument slices")

uni <- read_parquet("data/uni_lemma_summaries.parquet") |>
  mutate(prop = round(prop, 4))

uni |>
  group_by(uni_lemma) |>
  group_walk(function(d, key) {
    d |>
      select(language, age, words, n, measure, prop) |>
      write_csv(file.path("slices/unilemmas", paste0(san(key$uni_lemma), ".csv")))
  })

uni |>
  group_by(uni_lemma) |>
  summarise(slug = san(first(uni_lemma)), n_languages = n_distinct(language),
            .groups = "drop") |>
  arrange(uni_lemma) |>
  write_json("slices/unilemmas/index.json")
message("wrote ", length(list.files("slices/unilemmas")), " uni-lemma slices")

dir.create("slices/admins", recursive = TRUE, showWarnings = FALSE)
read_parquet("data/administrations.parquet") |>
  filter(!is.na(age)) |>
  group_by(language, form) |>
  group_walk(function(d, key) {
    d |>
      select(age, production, comprehension, is_norming, sex, birth_order,
             caregiver_education, ethnicity) |>
      write_csv(file.path("slices/admins",
                          paste0(san(paste(key$language, key$form)), ".csv")),
                na = "")
  })
message("wrote ", length(list.files("slices/admins")), " admin slices")
