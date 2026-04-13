#!/usr/bin/env bash
set -euo pipefail
# -----------------------------------------------------------------------------
# File: .github/scripts/update-readme-blog-posts.sh
# Purpose: Refresh the README.md blog section using the latest RSS feed entries.
# Summary:
#   - Fetch RSS content from the configured RSS_URL
#   - Build a Markdown table of recent blog posts
#   - Replace only the section between the README marker lines
# Requirements:
#   - curl
#   - perl
#   - awk
#   - GNU date
# Usage:
#   .github/scripts/update-readme-blog-posts.sh
# -----------------------------------------------------------------------------
# This script intentionally modifies only the content between marker lines.
# -----------------------------------------------------------------------------

RSS_URL="https://nadzu.me/rss.xml"
README_FILE="README.md"
START_MARKER="<!-- nadzu-blog-post-start -->"
END_MARKER="<!-- nadzu-blog-post-end -->"
MAX_POSTS=10

TMP_DIR="$(mktemp -d)"
RSS_FILE="$TMP_DIR/feed.xml"
TABLE_FILE="$TMP_DIR/table.md"
README_TMP="$TMP_DIR/README.md.tmp"
trap 'rm -rf "$TMP_DIR"' EXIT

log() {
  printf '%s\n' "$*"
}

require_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    log "Error: Required file not found: $path"
    exit 1
  fi
}

require_marker() {
  local marker="$1"
  if ! grep -qF "$marker" "$README_FILE"; then
    log "Error: Marker not found in $README_FILE: $marker"
    exit 1
  fi
}

extract_tag() {
  local xml_block="$1"
  local tag_name="$2"

  TAG_NAME="$tag_name" perl -0777 -ne '
    my $tag = $ENV{"TAG_NAME"};
    if (m|<$tag(?:\s+[^>]*)?>\s*(.*?)\s*</$tag>|s) {
      my $value = $1;
      $value =~ s/\s+/ /g;
      $value =~ s/^\s+|\s+$//g;
      print $value;
    }
  ' <<< "$xml_block"
}

format_date() {
  local pub_date="$1"
  local formatted=""

  if formatted=$(date -u -d "$pub_date" '+%Y-%b-%d' 2>/dev/null | tr '[:lower:]' '[:upper:]'); then
    printf '%s' "$formatted"
  else
    # Keep workflow resilient if the feed has an unexpected date format.
    printf 'Unknown'
  fi
}

build_table() {
  local rss_file="$1"
  local table_file="$2"

  local total_posts=0
  local selected_posts=0

  {
    printf '| Date | Title | Link |\n'
    printf '| --- | --- | --- |\n'

    while IFS= read -r -d '' item_block; do
      total_posts=$((total_posts + 1))

      if (( selected_posts >= MAX_POSTS )); then
        continue
      fi

      local title
      local link
      local pub_date
      local formatted_date
      local safe_title

      title="$(extract_tag "$item_block" "title")"
      link="$(extract_tag "$item_block" "link")"
      pub_date="$(extract_tag "$item_block" "pubDate")"

      if [[ -z "$link" ]]; then
        link="$(extract_tag "$item_block" "guid")"
      fi

      if [[ -z "$title" || -z "$link" ]]; then
        continue
      fi

      formatted_date="$(format_date "$pub_date")"
      safe_title="${title//|/\\|}"

      printf '| %s | %s | [Read](%s) |\n' "$formatted_date" "$safe_title" "$link"
      selected_posts=$((selected_posts + 1))
    done < <(perl -0777 -ne 'while (m|<item\b[^>]*>(.*?)</item>|sg) { print "$1\0"; }' "$rss_file")

    if (( total_posts == 0 )); then
      return 10
    fi

    if (( selected_posts == 0 )); then
      return 11
    fi
  } > "$table_file"

  return 0
}

replace_readme_section() {
  local table_file="$1"

  awk -v start="$START_MARKER" -v end="$END_MARKER" -v table_path="$table_file" '
    BEGIN { in_block = 0; replaced = 0 }

    {
      if (index($0, start) > 0) {
        print $0
        while ((getline line < table_path) > 0) {
          print line
        }
        close(table_path)
        in_block = 1
        replaced = 1
        next
      }

      if (index($0, end) > 0) {
        in_block = 0
        print $0
        next
      }

      if (!in_block) {
        print $0
      }
    }

    END {
      if (replaced == 0) {
        exit 2
      }
    }
  ' "$README_FILE" > "$README_TMP"

  mv "$README_TMP" "$README_FILE"
}

main() {
  require_file "$README_FILE"
  require_marker "$START_MARKER"
  require_marker "$END_MARKER"

  log "Fetching RSS feed from $RSS_URL"
  curl --fail --silent --show-error --location "$RSS_URL" -o "$RSS_FILE"

  set +e
  build_table "$RSS_FILE" "$TABLE_FILE"
  build_status=$?
  set -e

  if [[ $build_status -eq 10 ]]; then
    log "No blog posts found in feed. Exiting without README changes."
    exit 0
  fi

  if [[ $build_status -eq 11 ]]; then
    log "Feed had items, but none were valid for rendering. Exiting without changes."
    exit 0
  fi

  if [[ $build_status -ne 0 ]]; then
    log "Error: Failed to build Markdown table from feed."
    exit 1
  fi

  replace_readme_section "$TABLE_FILE"
  log "README.md blog section updated successfully."
}

main "$@"
