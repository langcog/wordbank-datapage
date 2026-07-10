#!/usr/bin/env Rscript
# Compute Gemini embeddings for every unique word item definition, across all
# languages (gemini-embedding-001 is multilingual, so all items share one
# semantic space — this is what enables cross-linguistic networks).
# Resumable: already-embedded definitions are skipped on re-runs.
# Output: data/item_embeddings.parquet
#   (language, item_definition, embedding = list column of 768 floats)

suppressMessages({
  library(dplyr)
  library(purrr)
  library(arrow)
  library(httr)
  library(jsonlite)
})

readRenviron(".secrets")
api_key <- Sys.getenv("GEMINI_API_KEY")
stopifnot(nzchar(api_key))

MODEL <- "gemini-embedding-001"
DIM <- 768
BATCH <- 100
out_path <- "data/item_embeddings.parquet"

words <- read_parquet("data/items.parquet") |>
  filter(item_kind == "word") |>
  distinct(language, item_definition) |>
  filter(!is.na(item_definition), item_definition != "")

done <- if (file.exists(out_path)) {
  read_parquet(out_path)
} else {
  tibble(language = character(), item_definition = character(),
         embedding = list())
}
todo <- anti_join(words, done, by = c("language", "item_definition"))
message(nrow(done), " cached, ", nrow(todo), " to embed")

embed_batch <- function(texts) {
  body <- list(requests = map(texts, \(x) list(
    model = paste0("models/", MODEL),
    content = list(parts = list(list(text = x))),
    taskType = "SEMANTIC_SIMILARITY",
    outputDimensionality = DIM
  )))
  for (attempt in 1:5) {
    resp <- POST(
      sprintf("https://generativelanguage.googleapis.com/v1beta/models/%s:batchEmbedContents?key=%s",
              MODEL, api_key),
      body = toJSON(body, auto_unbox = TRUE), encode = "raw",
      content_type_json())
    if (status_code(resp) == 200) {
      out <- content(resp, "parsed", simplifyVector = FALSE)
      return(map(out$embeddings, \(e) as.numeric(unlist(e$values))))
    }
    message("  HTTP ", status_code(resp), ", retrying in ", 10 * attempt, "s")
    Sys.sleep(10 * attempt)
  }
  stop("embedding batch failed after retries")
}

batches <- split(seq_len(nrow(todo)), ceiling(seq_len(nrow(todo)) / BATCH))
for (bi in seq_along(batches)) {
  idx <- batches[[bi]]
  vecs <- embed_batch(todo$item_definition[idx])
  done <- bind_rows(done, tibble(
    language = todo$language[idx],
    item_definition = todo$item_definition[idx],
    embedding = vecs
  ))
  # checkpoint every 20 batches so interruption loses little work
  if (bi %% 20 == 0 || bi == length(batches)) {
    write_parquet(done, out_path)
    message("batch ", bi, "/", length(batches), " (", nrow(done), " embedded)")
  }
}
message("done: ", nrow(done), " embeddings at dim ", DIM)
