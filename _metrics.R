# ---------------------------------------------------------------------------
# _metrics.R — single source of truth for every live number on the site.
#
# Sourced by: index.qmd, it/index.qmd, statistics.qmd, it/statistics.qmd,
#             software.qmd, it/software.qmd
#
# `execute-dir: project` in _quarto.yml means every page — including the ones
# under it/ — resolves this file and the cache files from the project root.
# Do not add "../" anywhere.
#
# Why a shared file: the same four numbers used to be fetched independently by
# each page, which meant up to six Google Scholar hits per full render and two
# copies of every formatter to keep in sync. Now each remote source is fetched
# at most once per render (see the TTL below) and cached to disk, so a network
# failure degrades to the last known good value instead of printing "N/A".
#
# CACHES (both are committed to git — that is how the CI build gets its data):
#   scholar_cache.json  profile + citation history + publication count
#   metrics_cache.json  CRAN download totals
# ---------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(jsonlite)
  library(cranlogs)
})

# ---- Configuration --------------------------------------------------------

SCHOLAR_ID    <- "Qu66YZQAAAAJ"
CAREER_START  <- 2007L   # academic career began 2007-01-01; drives the folio "Vol."
CRAN_PACKAGES <- c("bibliometrix", "openalexR", "dimensionsR", "pubmedR",
                   "e2tree", "contentanalysis", "tall")
CRAN_SINCE    <- "2015-01-01"

SCHOLAR_CACHE <- "scholar_cache.json"
METRICS_CACHE <- "metrics_cache.json"

# A full render executes six documents in six separate R sessions. Without a
# TTL each one would re-hit Scholar and CRAN. Six hours is long enough to cover
# one render, short enough that a weekly run always refetches.
METRICS_TTL_HOURS <- 6

# ---- Cache plumbing -------------------------------------------------------

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a

.read_cache <- function(path) {
  if (!file.exists(path)) return(NULL)
  tryCatch(jsonlite::read_json(path, simplifyVector = TRUE), error = function(e) NULL)
}

.write_cache <- function(obj, path) {
  tryCatch(
    jsonlite::write_json(obj, path, auto_unbox = TRUE, pretty = TRUE),
    error = function(e) invisible(NULL)
  )
}

.now_utc <- function() format(as.POSIXct(Sys.time(), tz = "UTC"), "%Y-%m-%dT%H:%M:%SZ")

# TRUE when the cache was written less than METRICS_TTL_HOURS ago, i.e. another
# document in this same render already did the fetching.
.cache_is_fresh <- function(cache) {
  if (is.null(cache) || is.null(cache$fetched_at)) return(FALSE)
  ts <- tryCatch(as.POSIXct(cache$fetched_at, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
                 error = function(e) NA)
  if (is.na(ts)) return(FALSE)
  difftime(Sys.time(), ts, units = "hours") < METRICS_TTL_HOURS
}

# ---- Google Scholar -------------------------------------------------------

# Returns: list(total_cites, h_index, i10_index, n_pubs, cite_history, ok)
# `ok = TRUE` means this render actually reached Scholar. `ok = FALSE` means
# everything below came from scholar_cache.json — which is the normal, expected
# outcome on GitHub Actions, whose IP ranges Scholar refuses.
metrics_scholar <- function() {
  cache <- .read_cache(SCHOLAR_CACHE)

  fetched <- NULL
  if (!.cache_is_fresh(cache) && requireNamespace("scholar", quietly = TRUE)) {
    fetched <- tryCatch({
      p  <- scholar::get_profile(SCHOLAR_ID)
      ch <- scholar::get_citation_history(SCHOLAR_ID)
      if (!is.list(p) || is.null(p$total_cites)) stop("invalid profile")
      if (!is.data.frame(ch) || nrow(ch) == 0)   stop("invalid citation history")

      # Publication count: Scholar entries carrying a venue, deduplicated on a
      # normalised title. The raw list holds ~80 extra rows with no venue plus a
      # handful of exact-title duplicates (arXiv preprint alongside the journal
      # version, an "Author response", ...) that would inflate the figure.
      n_pubs <- tryCatch({
        pubs <- scholar::get_publications(SCHOLAR_ID)
        venue <- pubs[nzchar(pubs$journal), , drop = FALSE]
        length(unique(gsub("[^a-z0-9]", "", tolower(venue$title))))
      }, error = function(e) NA_integer_)

      list(profile = p, cite_history = ch, n_pubs = n_pubs,
           fetched_at = .now_utc(), ok = TRUE)
    }, error = function(e) NULL)
  }

  if (!is.null(fetched)) {
    # Carry a previous publication count over rather than regressing to NA if
    # only get_publications() failed.
    if (is.na(fetched$n_pubs) && !is.null(cache$n_pubs)) fetched$n_pubs <- cache$n_pubs
    .write_cache(fetched, SCHOLAR_CACHE)
    cache <- fetched
  }

  if (is.null(cache)) {
    return(list(total_cites = NA_integer_, h_index = NA_integer_,
                i10_index = NA_integer_, n_pubs = NA_integer_,
                cite_history = NULL, ok = FALSE))
  }

  ch <- cache$cite_history
  if (!is.null(ch) && !is.data.frame(ch)) ch <- as.data.frame(ch)

  list(
    total_cites  = as.integer(cache$profile$total_cites %||% NA),
    h_index      = as.integer(cache$profile$h_index     %||% NA),
    i10_index    = as.integer(cache$profile$i10_index   %||% NA),
    n_pubs       = as.integer(cache$n_pubs              %||% NA),
    cite_history = ch,
    ok           = isTRUE(cache$ok) && (!is.null(fetched) || .cache_is_fresh(cache))
  )
}

# ---- CRAN -----------------------------------------------------------------

# Total downloads per package since CRAN_SINCE. Only the totals are cached;
# statistics.qmd still fetches the full daily series itself, because it needs
# the time axis for its charts.
metrics_cran_totals <- function(packages = CRAN_PACKAGES) {
  cache <- .read_cache(METRICS_CACHE)
  cached <- cache$cran_totals

  if (.cache_is_fresh(cache) && all(packages %in% names(cached))) {
    return(vapply(packages, function(p) as.numeric(cached[[p]]), numeric(1)))
  }

  totals <- vapply(packages, function(pkg) {
    tryCatch({
      dl <- cran_downloads(pkg, from = CRAN_SINCE, to = Sys.Date())
      sum(dl$count, na.rm = TRUE)
    }, error = function(e) NA_real_)
  }, numeric(1))

  # Which packages actually came back from the network on this call. Recorded
  # before the fallback below, so a value restored from cache is never mistaken
  # for a fresh fetch.
  from_network <- !is.na(totals)

  # Any package CRAN did not answer for keeps its last known total.
  for (pkg in packages) {
    if (is.na(totals[[pkg]]) && !is.null(cached[[pkg]])) {
      totals[[pkg]] <- as.numeric(cached[[pkg]])
    }
  }

  # Only stamp a new fetched_at when something was really downloaded. Otherwise
  # a CRAN outage would refresh the timestamp on untouched data, making a stale
  # cache look fresh and suppressing retries for the whole TTL window.
  if (any(from_network)) {
    merged <- if (is.null(cached)) list() else as.list(cached)
    for (pkg in packages[from_network]) merged[[pkg]] <- totals[[pkg]]
    .write_cache(list(cran_totals = merged, fetched_at = .now_utc()), METRICS_CACHE)
  }

  totals
}

metrics_cran_total <- function(pkg) unname(metrics_cran_totals(pkg)[[1]])

# ---- Formatters -----------------------------------------------------------

fmt_int <- function(x) {
  if (length(x) == 0 || is.na(x) || !is.finite(x)) return("—")
  formatC(x, format = "d", big.mark = ",")
}

# 1,553,969 -> "1.55M" ; 980,000 -> "980K"
fmt_compact <- function(x) {
  if (length(x) == 0 || is.na(x) || !is.finite(x)) return("—")
  if (x >= 1e6) sprintf("%.2fM", x / 1e6)
  else if (x >= 1e3) sprintf("%.0fK", x / 1e3)
  else formatC(x, format = "d", big.mark = ",")
}

# Round down so a trailing "+" is always literally true.
fmt_floor <- function(x, to = 100) {
  if (length(x) == 0 || is.na(x) || !is.finite(x)) return("—")
  fmt_int(floor(x / to) * to)
}

# ---- Dateline -------------------------------------------------------------

metrics_year        <- function() as.integer(format(Sys.Date(), "%Y"))
metrics_year_roman  <- function() as.character(utils::as.roman(metrics_year()))

# Volume number of the folio masthead: the current year of the academic career,
# counted inclusively from CAREER_START (2007 -> Vol. I, 2026 -> Vol. XX).
metrics_volume_roman <- function() {
  as.character(utils::as.roman(metrics_year() - CAREER_START + 1L))
}
