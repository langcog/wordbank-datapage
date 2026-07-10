#!/usr/bin/env Rscript
# Cache age-of-acquisition estimates for every word item on every instrument,
# using wordbankr::fit_aoa (glm method) on the local extraction output.
# Output: data/aoa.parquet (language, form, item metadata, measure, aoa).

suppressMessages({
  library(wordbankr)
  library(dplyr)
  library(purrr)
  library(arrow)
})

admins <- read_parquet("data/administrations.parquet") |>
  filter(in_age_range) |>
  select(data_id, age)
items <- read_parquet("data/items.parquet") |>
  select(language, form, item_id, item_kind, item_definition, category,
         uni_lemma)

safe_fit <- purrr::safely(wordbankr::fit_aoa)

aoa <- map(list.files("data/item_responses", full.names = TRUE), function(f) {
  d <- read_parquet(f) |>
    inner_join(items, by = c("language", "form", "item_id")) |>
    filter(item_kind == "word") |>
    inner_join(admins, by = "data_id")
  if (nrow(d) == 0) return(NULL)
  message(basename(f))

  measures <- c("produces", if (!all(is.na(d$understands))) "understands")
  map(measures, function(m) {
    dd <- filter(d, !is.na(.data[[m]]))
    res <- safe_fit(dd, measure = m)
    if (is.null(res$result)) {
      message("  fit_aoa failed for ", m, ": ", conditionMessage(res$error))
      return(NULL)
    }
    res$result |>
      transmute(language = d$language[[1]], form = d$form[[1]], item_id,
                item_definition, category, uni_lemma, measure = m,
                aoa = as.numeric(aoa))
  }) |> list_rbind()
}) |> list_rbind()

write_parquet(aoa, "data/aoa.parquet")
message("wrote data/aoa.parquet: ", nrow(aoa), " rows, ",
        sum(!is.na(aoa$aoa)), " with estimates")
