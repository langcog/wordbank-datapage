# wordbank-datapage

A static rebuild of [wordbank.stanford.edu](http://wordbank.stanford.edu) on the
[datapages](https://github.com/datapages/datapage) infrastructure: data hosted on
[Redivis](https://redivis.com/datapages) (versioned, free), site built with Quarto,
visualization in-browser with Observable Plot. Intended to nondestructively supersede
the Django + Shiny stack ([wordbank](https://github.com/langcog/wordbank),
[wordbank-shiny](https://github.com/langcog/wordbank-shiny)).

## Architecture

```
wordbank MySQL (RDS)  --etl/extract_wordbank.R-->  data/*.parquet
data/*.parquet        --etl/upload_redivis.R--->   Redivis: datapages.wordbank (new version)
Redivis               --lazy per-instrument load-->  Quarto/OJS site (GitHub Pages)
```

New data continues to enter the MySQL database through the existing wordbank import
pipeline; a data release = re-running the ETL, which publishes a new Redivis version.

## Tables

Core (shaped like the corresponding `wordbankr` return values):

| table | grain | source |
|---|---|---|
| `instruments` | language-form | `get_instruments()` |
| `datasets` | contributed dataset (carries `license`, incl. CC-BY-NC) | `get_datasets()` |
| `administrations` | child × test | `get_administration_data(include_* = TRUE)` |
| `children` | child | distinct child rows from administrations |
| `language_exposures` | administration × language | unnested from administrations |
| `health_conditions` | child × condition | unnested from administrations |
| `items` | item × instrument | `get_item_data()` |
| `item_responses` | administration × item (long) | `get_instrument_data()` per instrument |

Derived (power the site's visualizations):

| table | grain | replaces |
|---|---|---|
| `item_summaries` | instrument × item × age × measure → proportion | item_trajectories / item_data apps |
| `uni_lemma_summaries` | language × uni_lemma × age × measure → proportion | uni_lemmas app (`all_prop_data.feather`) |
| `vocab_summaries` | instrument × measure × age → empirical quantiles | vocab_norms app (model fits deferred) |

## ETL

```sh
# credentials: put REDIVIS_API_TOKEN=... in .secrets (gitignored)
Rscript etl/extract_wordbank.R          # full extraction (~89 instruments)
Rscript etl/extract_wordbank.R --test   # smoke test on a few small instruments
Rscript etl/upload_redivis.R            # push data/ to Redivis as a new version
```

Requires R packages: `wordbankr` (>= 1.0), `redivis`, `arrow`, `tidyverse`.
