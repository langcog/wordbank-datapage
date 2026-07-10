#!/usr/bin/env Rscript
# Fetch the tables the site needs at render time from Redivis into data/.
# Used by CI (which has no local ETL output); requires REDIVIS_API_TOKEN.
# item_responses is not fetched — the site never loads it.

suppressMessages({
  library(redivis)
  library(arrow)
})

if (file.exists(".secrets")) readRenviron(".secrets")

# the rest of the site's data comes from the committed slices/responses
tables <- c("instruments", "administrations", "datasets")

dir.create("data", showWarnings = FALSE)
ds <- redivis$organization("datapages")$dataset("wordbank")
for (t in tables) {
  message("fetching ", t)
  write_parquet(ds$table(t)$to_tibble(), file.path("data", paste0(t, ".parquet")))
}
