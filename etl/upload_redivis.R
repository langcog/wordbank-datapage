#!/usr/bin/env Rscript
# Upload data/*.parquet (from extract_wordbank.R) to Redivis as the
# datapages.wordbank dataset. Creates the dataset on first run; afterwards
# creates a new version, replaces all tables, and releases.
#
# Requires REDIVIS_API_TOKEN in .secrets (KEY=VALUE format, gitignored).
#
# Usage: Rscript etl/upload_redivis.R ["release notes"]

suppressMessages({
  library(redivis)
  library(stringr)
})

if (file.exists(".secrets")) readRenviron(".secrets")
if (Sys.getenv("REDIVIS_API_TOKEN") == "") stop("REDIVIS_API_TOKEN not set")

notes <- commandArgs(trailingOnly = TRUE)
notes <- if (length(notes) > 0) notes[[1]] else
  paste("Automated extraction from the wordbank database,", Sys.Date())

out_dir <- "data"
resp_dir <- file.path(out_dir, "item_responses")

table_descriptions <- c(
  instruments = "One row per CDI instrument (language-form pair).",
  datasets = "One row per contributed dataset. The license column marks CC-BY vs CC-BY-NC datasets.",
  administrations = "One row per administration (a child completing an instrument once), with demographics.",
  children = "One row per child, demographic fields constant across administrations.",
  language_exposures = "Per-administration language exposure for bilingual children (keyed by data_id).",
  health_conditions = "Child health conditions (keyed by child_id).",
  items = "One row per item on each instrument, with category and cross-linguistic uni_lemma mappings.",
  item_summaries = "Per instrument: item x age x measure -> proportion of children producing/understanding.",
  uni_lemma_summaries = "Cross-linguistic: language x uni_lemma x age x measure -> proportion (uni-lemmas in 2+ languages).",
  vocab_summaries = "Per instrument: measure x age -> empirical vocabulary-size quantiles (10/25/50/75/90).",
  item_responses = "Long-format raw responses: one row per administration x item, all instruments."
)

ds <- redivis$organization("datapages")$dataset("wordbank")
if (!ds$exists()) {
  message("creating dataset datapages.wordbank")
  ds$create(public_access_level = "data",
            description = "Wordbank: an open database of children's vocabulary development. CDI administrations across 89 instruments. See wordbank.stanford.edu and langcog/wordbank-datapage.")
} else {
  message("creating next version of datapages.wordbank")
  ds <- ds$create_next_version(if_not_exists = TRUE)
}

upload_parquet <- function(tb, path) {
  tb$upload(basename(path))$create(content = path, type = "parquet")
}

for (f in list.files(out_dir, pattern = "\\.parquet$", full.names = TRUE)) {
  tname <- str_remove(basename(f), "\\.parquet$")
  message("uploading table: ", tname)
  tb <- ds$table(tname)
  if (!tb$exists()) tb$create(description = table_descriptions[[tname]],
                              upload_merge_strategy = "replace")
  upload_parquet(tb, f)
}

message("uploading table: item_responses (per-instrument files, appended)")
tb <- ds$table("item_responses")
if (!tb$exists()) tb$create(description = table_descriptions[["item_responses"]],
                            upload_merge_strategy = "replace")
for (f in list.files(resp_dir, full.names = TRUE)) {
  message("  ", basename(f))
  upload_parquet(tb, f)
}

message("releasing version...")
ds$release(release_notes = notes)
message("done: https://redivis.com/datasets?organization=datapages")
