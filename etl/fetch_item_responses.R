#!/usr/bin/env Rscript
# Fetch item_responses from Redivis into data/item_responses/<language_form>.parquet,
# one file per instrument, in the shape extract_wordbank.R produces — so the
# derived tables and site slices can be rebuilt from a Redivis version without
# access to the MySQL database.
#
# Usage: Rscript etl/fetch_item_responses.R [version]   (default "next")
# Resumable: existing files are skipped. Requires REDIVIS_API_TOKEN.

suppressMessages({
  library(redivis)
  library(arrow)
  library(dplyr)
  library(stringr)
})

if (file.exists(".secrets")) readRenviron(".secrets")
if (Sys.getenv("REDIVIS_API_TOKEN") == "") stop("REDIVIS_API_TOKEN not set")

args <- commandArgs(trailingOnly = TRUE)
version <- if (length(args) > 0) args[[1]] else "next"
san <- function(x) x |> str_to_lower() |> str_replace_all("[^a-z0-9]+", "_") |>
  str_replace_all("^_|_$", "")

ref <- sprintf("`datapages.wordbank:627v:%s.%s`", str_replace_all(version, "\\.", "_"), "%s")
resp_dir <- "data/item_responses"
dir.create(resp_dir, recursive = TRUE, showWarnings = FALSE)

insts <- redivis$query(sprintf("SELECT instrument_id, language, form FROM %s ORDER BY language, form",
                               sprintf(ref, "instruments")))$to_tibble()
for (i in seq_len(nrow(insts))) {
  inst <- insts[i, ]
  path <- file.path(resp_dir, paste0(san(paste(inst$language, inst$form)), ".parquet"))
  if (file.exists(path)) next
  message(sprintf("[%d/%d] %s %s", i, nrow(insts), inst$language, inst$form))
  q <- sprintf("SELECT instrument_id, language, form, data_id, item_id, value, produces, understands
                FROM %s WHERE language = '%s' AND form = '%s'",
               sprintf(ref, "item_responses"),
               str_replace_all(inst$language, "'", "\\\\'"), str_replace_all(inst$form, "'", "\\\\'"))
  tbl <- redivis$query(q)$to_arrow_table()
  write_parquet(tbl, path)
}
message("done: ", length(list.files(resp_dir)), " instrument files")
