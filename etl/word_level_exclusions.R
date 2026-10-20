# Datasets left out of the site's word-level views (item trajectories,
# cross-linguistic trajectories, semantic networks, and the Data page
# downloads, which are built from the same response slices) while their
# item-level data are known to be wrong. Their administration totals still
# feed the vocabulary norms. Delete an entry once the import is fixed.
#   Elison: item responses attached to the wrong items (langcog/wordbank-import#10)
word_level_exclude <- c("Elison")
