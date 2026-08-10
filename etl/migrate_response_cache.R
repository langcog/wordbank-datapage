#!/usr/bin/env Rscript
# One-time migration of cached data/item_responses/*.parquet for v1.6:
# cast instrument_id/data_id to integer and normalize ASL CDITwo item ids
# ("Item_N" -> "item_N"). Idempotent; safe to delete after the v1.6 release.

suppressMessages({
  library(dplyr)
  library(stringr)
  library(arrow)
})

files <- list.files("data/item_responses", full.names = TRUE)
for (f in files) {
  resp <- read_parquet(f)
  needs_cap_fix <- any(str_detect(resp$item_id, "^Item_"))
  needs_int <- !is.integer(resp$data_id) || !is.integer(resp$instrument_id)
  if (!needs_cap_fix && !needs_int) next
  resp <- resp |>
    mutate(instrument_id = as.integer(instrument_id),
           data_id = as.integer(data_id),
           item_id = str_replace(item_id, "^Item_", "item_"))
  write_parquet(resp, f)
  message(basename(f), ": ",
          if (needs_int) "int-cast " else "",
          if (needs_cap_fix) "item_id-normalized" else "")
}
message("done: ", length(files), " files checked")

# aoa cache carries item_id too; normalize without refitting
if (file.exists("data/aoa.parquet")) {
  aoa <- read_parquet("data/aoa.parquet")
  if (any(str_detect(aoa$item_id, "^Item_"))) {
    aoa <- mutate(aoa, item_id = str_replace(item_id, "^Item_", "item_"))
    write_parquet(aoa, "data/aoa.parquet")
    message("aoa.parquet: item_id normalized")
  }
}
