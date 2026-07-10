#!/usr/bin/env Rscript
# Write per-selection data slices for the site.
#
# Part A (data release, needs full local ETL output in data/item_responses/):
#   slices/responses/<language_form>.parquet  raw item-level responses with
#     demographics, uni_lemma, and item metadata joined. These are COMMITTED
#     to git (~12 MB total) so CI can build everything else from them.
#
# Part B (runs anywhere, incl. CI; needs data/administrations.parquet and
# slices/responses/):
#   slices/admins/<language_form>.csv  administrations for one instrument
#   slices/unilemmas/<uni_lemma>.csv   per-lemma cross-linguistic proportions
#     with sex split ("All"/"Female"/"Male")
#   slices/unilemmas/index.json        available uni-lemmas + language counts

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

# site slices keep the usual in-range view; the canonical Redivis table has
# everything (older extracts lack the flag, hence the any_of fallback)
admins <- read_parquet("data/administrations.parquet") |> filter(!is.na(age))
if ("in_age_range" %in% names(admins)) admins <- filter(admins, in_age_range)

# ---- Part A: response parquets (only when full extract is present) ----------

if (dir.exists("data/item_responses")) {
  dir.create("slices/responses", recursive = TRUE, showWarnings = FALSE)
  admins_demo <- admins |>
    select(data_id, age, is_norming, sex, birth_order, caregiver_education,
           ethnicity)
  item_meta <- read_parquet("data/items.parquet") |>
    select(language, form, item_id, item_kind, item_definition, category,
           uni_lemma) |>
    filter(item_kind == "word" | !is.na(uni_lemma))

  for (f in list.files("data/item_responses", full.names = TRUE)) {
    resp <- read_parquet(f) |>
      inner_join(item_meta, by = c("language", "form", "item_id")) |>
      inner_join(admins_demo, by = "data_id") |>
      select(language, data_id, item_id, item_kind, item_definition, category,
             uni_lemma, age, produces, understands, is_norming, sex,
             birth_order, caregiver_education, ethnicity)
    if (nrow(resp) > 0)
      write_parquet(resp, file.path("slices/responses", basename(f)),
                    compression = "zstd")
  }
  message("wrote ", length(list.files("slices/responses")), " response slices")
} else {
  message("no data/item_responses; using committed slices/responses")
}

# ---- Part B: admin CSVs and uni-lemma slices --------------------------------

dir.create("slices/admins", recursive = TRUE, showWarnings = FALSE)
admins |>
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

# per-lemma slices, recomputed from the response parquets so they carry a sex
# split; "All" rows reproduce uni_lemma_summaries (pooling across all forms
# per language, mirroring the old uni_lemmas/print_all_prop_data.R)
dir.create("slices/unilemmas", recursive = TRUE, showWarnings = FALSE)

uni_counts <- map(
  list.files("slices/responses", full.names = TRUE),
  function(f) {
    read_parquet(f) |>
      filter(!is.na(uni_lemma)) |>
      mutate(sex = as.character(sex),
             sex = if_else(is.na(sex) | sex == "", "Unknown", sex)) |>
      group_by(language, uni_lemma, age, sex) |>
      summarise(words = paste(unique(unlist(strsplit(item_definition, ", "))),
                              collapse = ", "),
                produces = sum(produces, na.rm = TRUE),
                understands = sum(understands, na.rm = TRUE),
                n_responses = n(),
                n_children = n_distinct(data_id),
                .groups = "drop")
  }) |>
  list_rbind() |>
  group_by(language, uni_lemma, age, sex) |>
  summarise(words = paste(unique(unlist(strsplit(words, ", "))), collapse = ", "),
            produces = sum(produces), understands = sum(understands),
            n_responses = sum(n_responses), n = sum(n_children),
            .groups = "drop")

uni <- bind_rows(
  uni_counts |> mutate(sex = "All") |>
    group_by(language, uni_lemma, age, sex) |>
    summarise(words = paste(unique(unlist(strsplit(words, ", "))), collapse = ", "),
              produces = sum(produces), understands = sum(understands),
              n_responses = sum(n_responses), n = sum(n),
              .groups = "drop"),
  uni_counts |> filter(sex %in% c("Female", "Male"))
) |>
  mutate(produces = round(produces / n_responses, 4),
         understands = round(understands / n_responses, 4)) |>
  select(-n_responses) |>
  tidyr::pivot_longer(c(produces, understands),
                      names_to = "measure", values_to = "prop") |>
  group_by(uni_lemma) |>
  filter(n_distinct(language[sex == "All"]) > 1) |>
  ungroup()

uni |>
  group_by(uni_lemma) |>
  group_walk(function(d, key) {
    d |>
      select(language, sex, age, words, n, measure, prop) |>
      write_csv(file.path("slices/unilemmas", paste0(san(key$uni_lemma), ".csv")))
  })

uni |>
  group_by(uni_lemma) |>
  summarise(slug = san(first(uni_lemma)), n_languages = n_distinct(language),
            .groups = "drop") |>
  arrange(uni_lemma) |>
  write_json("slices/unilemmas/index.json")
message("wrote ", length(list.files("slices/unilemmas")), " uni-lemma slices")

# ---- Part C: network slices (need data/aoa.parquet + item_embeddings) ------
# one row per unique word definition per language: AoA (preferring WS-type
# production) + 256-dim normalized embedding (Matryoshka truncation of the
# 768-dim gemini embedding)

if (file.exists("data/aoa.parquet") && file.exists("data/item_embeddings.parquet")) {
  dir.create("slices/networks", recursive = TRUE, showWarnings = FALSE)

  form_pref <- read_parquet("data/instruments.parquet") |>
    mutate(pref = case_when(form_type == "WS" ~ 1, form_type == "WG" ~ 2,
                            .default = 3)) |>
    select(language, form, pref)

  aoa_best <- read_parquet("data/aoa.parquet") |>
    filter(measure == "produces", !is.na(aoa)) |>
    inner_join(form_pref, by = c("language", "form")) |>
    group_by(language, item_definition) |>
    arrange(pref, aoa) |>
    slice(1) |>
    ungroup() |>
    select(language, item_definition, category, uni_lemma, aoa)

  emb <- read_parquet("data/item_embeddings.parquet") |>
    mutate(embedding = purrr::map(embedding, function(v) {
      v <- v[1:256]
      v / sqrt(sum(v^2))
    }))

  net <- aoa_best |>
    inner_join(emb, by = c("language", "item_definition"))

  net |>
    group_by(language) |>
    group_walk(function(d, key) {
      write_parquet(d, file.path("slices/networks",
                                 paste0(san(key$language), ".parquet")),
                    compression = "zstd")
    })
  message("wrote ", length(list.files("slices/networks")), " network slices (",
          nrow(net), " words)")
} else {
  message("skipping network slices (aoa/embeddings caches not present)")
}
