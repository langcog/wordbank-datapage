#!/usr/bin/env Rscript
# Set table descriptions and variable labels/descriptions on the
# datapages.wordbank Redivis dataset. Operates on the current next
# (unreleased) version if one exists, so the usual v-next flow is:
#
#   Rscript etl/upload_redivis.R --no-release
#   Rscript etl/set_metadata.R
#   Rscript -e 'library(redivis); redivis$organization("datapages")$dataset("wordbank")$release(release_notes = "...")'
#
# Requires REDIVIS_API_TOKEN in .secrets. Idempotent.

suppressMessages(library(redivis))

if (file.exists(".secrets")) readRenviron(".secrets")
if (Sys.getenv("REDIVIS_API_TOKEN") == "") stop("REDIVIS_API_TOKEN not set")

ds <- redivis$organization("datapages")$dataset("wordbank")

table_descriptions <- c(
  instruments = "One row per CDI instrument (language-form pair).",
  datasets = "One row per contributed dataset. The license column marks CC-BY vs CC-BY-NC datasets.",
  administrations = "One row per administration (a child completing an instrument once). Child-level variables live in children (join on child_id); instrument-level variables in instruments (join on language + form).",
  children = "One row per child; canonical home of demographic and birth variables (join to administrations on child_id).",
  language_exposures = "Per-administration language exposure for bilingual children (keyed by data_id); exposure_percentage runs 0-100.",
  health_conditions = "Child health conditions (keyed by child_id).",
  items = "One row per item on each instrument, with category and cross-linguistic uni_lemma mappings.",
  item_summaries = "Per instrument: item x age x measure -> proportion of children producing/understanding.",
  uni_lemma_summaries = "Cross-linguistic: language x uni_lemma x age x measure -> proportion (uni-lemmas in 2+ languages).",
  vocab_summaries = "Per instrument: measure x age -> empirical vocabulary-size quantiles (10/25/50/75/90).",
  aoa = "Age of acquisition per word item and measure: age at which 50% of children produce/understand the word (glm fit, wordbankr::fit_aoa).",
  item_embeddings = "Multilingual gemini-embedding-001 embeddings (768-dim, JSON array string) for each unique word item definition.",
  item_responses = "Long-format raw responses: one row per administration x item, all instruments."
)

# variable descriptions, per table; unlisted variables keep bare names
var_descriptions <- list(
  administrations = c(
    data_id = "Unique administration id; key into item_responses and language_exposures.",
    child_id = "Key into children (demographic and birth variables).",
    dataset_name = "Key into datasets (contributed dataset metadata and license).",
    language = "Instrument language; with form, key into instruments.",
    form = "Instrument form (e.g. WS, WG); with language, key into instruments.",
    age = "Child age in months at administration.",
    date_of_test = "Date of administration; missing where the source dataset did not record it.",
    comprehension = "Number of items the child understands. NA on WS-type forms except for the few datasets that genuinely measured comprehension (see langcog/wordbank#333).",
    production = "Number of items the child produces.",
    is_norming = "Administration is part of the instrument's norming sample.",
    in_age_range = "Age falls within the instrument's normed age range (age_min-age_max); the site and wordbankr filter to TRUE by default."
  ),
  children = c(
    child_id = "Unique child id (children can have multiple administrations, e.g. longitudinal datasets).",
    study_internal_id = "Child's id within the contributing study, where provided.",
    dataset_origin_name = "Name of the contributed dataset family the child comes from.",
    sex = "Factor: Female, Male, Other.",
    birth_order = "Factor: First, Second, ... (ordinal).",
    caregiver_education = "Factor, ordinal from None to Graduate.",
    ethnicity = "Factor (US-centric categories; missing for most non-US datasets).",
    race = "Factor (US-centric categories; missing for most non-US datasets).",
    birth_weight = "Birth weight in kilograms, where provided.",
    born_early_or_late = "Factor: Early / Late (relative to due date), where provided.",
    gestational_age = "Gestational age at birth in weeks, where provided.",
    zygosity = "Twin zygosity, where provided."
  ),
  item_responses = c(
    instrument_id = "Key into instruments.",
    data_id = "Key into administrations.",
    item_id = "Key into items (per instrument: language + form + item_id).",
    value = "Raw response as contributed. Empty string = item was presented and the child does not produce/understand it; NA = missing/not administered; other values are instrument-specific response categories (e.g. produces, understands, sometimes, often). See langcog/wordbank issue on value coding.",
    produces = "Recode of value: child produces the item. NA for non-word items where production is undefined.",
    understands = "Recode of value: child understands the item. NA except word items on WG-type forms (comprehension is only measured there)."
  ),
  language_exposures = c(
    data_id = "Key into administrations.",
    language = "Language the child is exposed to (free text from the source dataset).",
    exposure_percentage = "Percent of the child's language exposure (0-100); NA where unreported or out of range in the source data."
  ),
  instruments = c(
    instrument_id = "Unique instrument id.",
    form_type = "Form family: WS (Words & Sentences), WG (Words & Gestures), or other.",
    age_min = "Lower bound of the normed age range (months).",
    age_max = "Upper bound of the normed age range (months).",
    has_grammar = "Instrument includes grammar sections."
  ),
  datasets = c(
    dataset_name = "Unique dataset key (used by administrations).",
    dataset_origin_name = "Dataset family name (shared across forms).",
    n_admins = "Number of administrations contributed.",
    license = "Data license for this dataset (CC-BY or CC-BY-NC).",
    longitudinal = "Dataset includes repeated administrations of the same children."
  ),
  items = c(
    item_id = "Item id, unique within instrument (language + form).",
    item_kind = "Item type: word, gestures, word_endings, etc.; only word items have trajectories.",
    item_definition = "The item as printed on the form.",
    category = "CDI category (semantic/syntactic section of the form).",
    lexical_category = "Coarse lexical class used in analyses.",
    uni_lemma = "Cross-linguistic universal lemma mapping (English gloss), where assigned."
  ),
  vocab_summaries = c(
    quantile = "Quantile probability (0.10, 0.25, 0.50, 0.75, 0.90).",
    vocab = "Empirical vocabulary-size quantile at this age (rounded to 2 decimals)."
  ),
  aoa = c(
    aoa = "Estimated age (months) at which 50% of children produce/understand the item (glm on age)."
  ),
  item_embeddings = c(
    embedding = "JSON array string: 768-dim gemini-embedding-001 vector for this definition."
  )
)

for (tname in names(table_descriptions)) {
  tb <- ds$table(tname)
  ok <- tryCatch({ tb$update(description = table_descriptions[[tname]]); TRUE },
                 error = function(e) { message("  table ", tname, ": ",
                                               conditionMessage(e)); FALSE })
  if (!ok) next
  vars <- var_descriptions[[tname]]
  for (vname in names(vars)) {
    tryCatch(tb$variable(vname)$update(description = vars[[vname]]),
             error = function(e) message("  ", tname, ".", vname, ": ",
                                         conditionMessage(e)))
  }
  message("metadata set: ", tname,
          if (length(vars) > 0) paste0(" (", length(vars), " variables)") else "")
}
message("done")
