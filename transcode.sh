#!/bin/bash

set -euo pipefail

if [ "${#}" -ne 2 ]; then
	echo "Usage: ${0} <source_dir> <dest_dir>"
	exit 1
fi

SOURCE_DIR="${1}"
DEST_DIR="${2}"

if [ ! -d "${SOURCE_DIR}" ]; then
	echo "Source directory ${SOURCE_DIR} does not exist"
	exit 1
fi

mkdir -p "${DEST_DIR}"

INTERRUPTED=0
PROCESSED_FILES=0
COMPRESSED_FILES=0
MOVED_FILES=0
FAILED_FILES=0
TOTAL_ORIGINAL_SIZE=0
TOTAL_FINAL_SIZE=0
SCRIPT_START_TIME="$(date +%s)"

log() {
	echo "$(date -Is) - ${*}"
}

duration_h() {
	local seconds="${1}"
	local abs_seconds="${seconds}"

	if ((seconds < 0)); then
		abs_seconds="$((seconds * -1))"
	fi

	if ((abs_seconds == 0)); then
		echo "0 seconds"
		return
	fi

	local D="$((abs_seconds / 86400))"     # Days
	local H="$((abs_seconds / 3600 % 24))" # Hours
	local M="$((abs_seconds / 60 % 60))"   # Minutes
	local S="$((abs_seconds % 60))"        # Seconds

	local units=()

	if ((D > 0)); then
		units+=("${D} day$([[ "${D}" -gt 1 ]] && echo s)")
	fi
	if ((H > 0)); then
		units+=("${H} hour$([[ "${H}" -gt 1 ]] && echo s)")
	fi
	if ((M > 0)); then
		units+=("${M} minute$([[ "${M}" -gt 1 ]] && echo s)")
	fi
	if ((S > 0)); then
		units+=("${S} second$([[ "${S}" -gt 1 ]] && echo s)")
	fi

	local output=""
	local units_c="${#units[@]}"

	if ((units_c == 1)); then
		output="${units[0]}"
	else
		local i
		for ((i = 0; i < units_c - 2; i++)); do
			output+="${units[i]}, "
		done
		output+="${units[i]}"
		output+=" and ${units[units_c - 1]}"
	fi

	echo "${output}"
}

size_h() {
	local size_bytes="${1}"
	numfmt --to=iec-i --suffix=B "${size_bytes}" 2>/dev/null || echo "${size_bytes} bytes"
}

show_stats() {
	local script_end_time="$(date +%s)"
	local total_duration="$((script_end_time - SCRIPT_START_TIME))"

	if [ "${INTERRUPTED}" -eq 1 ]; then
		log "[INFO] Transcoding cancelled by user"
	else
		log "[INFO] Transcoding completed"
	fi
	log "========================================="
	log "Processed: ${PROCESSED_FILES}"
	log "Compressed: ${COMPRESSED_FILES}"
	log "Moved: ${MOVED_FILES}"
	log "Failed: ${FAILED_FILES}"
	log "Original Size: $(size_h "${TOTAL_ORIGINAL_SIZE}")"
	log "Final Size: $(size_h "${TOTAL_FINAL_SIZE}")"

	if [ "${TOTAL_ORIGINAL_SIZE}" -gt 0 ]; then
		local total_space_saved="$((TOTAL_ORIGINAL_SIZE - TOTAL_FINAL_SIZE))"
		local total_compression_ratio="$(awk "BEGIN {printf \"%.2f\", (${TOTAL_FINAL_SIZE} / ${TOTAL_ORIGINAL_SIZE}) * 100}")"
		log "Space Saved: $(size_h "${total_space_saved}")"
		log "Compression Ratio: ${total_compression_ratio}%"
	fi
	log "Duration: $(duration_h "${total_duration}")"
	log "========================================="
}

cleanup() {
	INTERRUPTED=1
	log "[INFO] Received interrupt signal, stopping processes"

	pkill -P "${$}" ffmpeg 2>/dev/null || true

	log "[INFO] Removing temporary files"
	find "${DEST_DIR}" -type f -name "*.tmp" -delete 2>/dev/null || true

	show_stats
	exit 130
}
trap cleanup SIGINT SIGTERM

get_file_size() {
	stat -c%s "${1}" 2>/dev/null || echo 0
}

is_hevc() {
	ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "${1}" 2>/dev/null | grep -qE '^(hevc|h265)$'
}

process_file() {
	local process_start_time="$(date +%s)"
	local src_file="${1}"
	local rel_path="$(realpath --relative-to="${SOURCE_DIR}" "${src_file}")"
	local dest_subdir="${DEST_DIR}/$(dirname "${rel_path}")"
	local basename="$(basename "${src_file}")"
	local name_no_ext="${basename%.*}"
	local dest_file="${dest_subdir}/${name_no_ext}.mp4"
	local temp_file="${dest_file}.tmp"

	mkdir -p "${dest_subdir}"

	local original_size="$(get_file_size "${src_file}")"

	log "[INFO] Processing: ${src_file}"

	if is_hevc "${src_file}"; then
		log "[INFO] Skipped: already in hevc, moving file to destination"
		if ! cp -p "${src_file}" "${temp_file}"; then
			log "[ERROR] Failed: cannot copy to ${temp_file}"
			FAILED_FILES="$((FAILED_FILES + 1))"
			PROCESSED_FILES="$((PROCESSED_FILES + 1))"
			rm -f "${temp_file}"
		else
			mv "${temp_file}" "${dest_file}"
			rm -f "${src_file}"
			MOVED_FILES="$((MOVED_FILES + 1))"
			PROCESSED_FILES="$((PROCESSED_FILES + 1))"
			TOTAL_FINAL_SIZE="$((TOTAL_FINAL_SIZE + original_size))"
			TOTAL_ORIGINAL_SIZE="$((TOTAL_ORIGINAL_SIZE + original_size))"
			log "[INFO] Saved: ${dest_file}"
		fi
	elif ffmpeg -nostdin -i "${src_file}" -c:v libx265 -crf 23 -preset medium -x265-params log-level=none -c:a aac -b:a 128k -vtag hvc1 -movflags +faststart -f mp4 "${temp_file}" -stats -loglevel error -hide_banner -y; then
		local converted_size="$(get_file_size "${temp_file}")"
		local ratio="$(awk "BEGIN {printf \"%.2f\", (${converted_size} / ${original_size}) * 100}")"
		log "[INFO] Compressed: $(size_h "${converted_size}")/$(size_h "${original_size}") (${ratio}%)"

		if [ "${converted_size}" -lt "${original_size}" ]; then
			mv "${temp_file}" "${dest_file}"
			rm -f "${src_file}"
			COMPRESSED_FILES="$((COMPRESSED_FILES + 1))"
			PROCESSED_FILES="$((PROCESSED_FILES + 1))"
			TOTAL_FINAL_SIZE="$((TOTAL_FINAL_SIZE + converted_size))"
			TOTAL_ORIGINAL_SIZE="$((TOTAL_ORIGINAL_SIZE + original_size))"
			log "[INFO] Saved: ${dest_file}"
		else
			log "[WARN] Converted file is larger, moving original file"
			rm -f "${temp_file}"
			if ! cp -p "${src_file}" "${temp_file}"; then
				log "[ERROR] Failed: cannot copy to ${temp_file}"
				FAILED_FILES="$((FAILED_FILES + 1))"
				PROCESSED_FILES="$((PROCESSED_FILES + 1))"
				rm -f "${temp_file}"
			else
				mv "${temp_file}" "${dest_file}"
				rm -f "${src_file}"
				MOVED_FILES="$((MOVED_FILES + 1))"
				PROCESSED_FILES="$((PROCESSED_FILES + 1))"
				TOTAL_FINAL_SIZE="$((TOTAL_FINAL_SIZE + original_size))"
				TOTAL_ORIGINAL_SIZE="$((TOTAL_ORIGINAL_SIZE + original_size))"
				log "[INFO] Saved: ${dest_file}"
			fi
		fi
	else
		log "[ERROR] Failed: cannot transcode video"
		FAILED_FILES="$((FAILED_FILES + 1))"
		PROCESSED_FILES="$((PROCESSED_FILES + 1))"
		rm -f "${temp_file}"
	fi

	local process_end_time="$(date +%s)"
	local duration="$((process_end_time - process_start_time))"
	log "[INFO] Duration: $(duration_h "${duration}")"
}

log "[INFO] Transcoding started"
log "[INFO] Source directory: ${SOURCE_DIR}"
log "[INFO] Destination directory: ${DEST_DIR}"

while IFS= read -r -d '' file; do
	process_file "${file}"
done < <(find "${SOURCE_DIR}" -type f \( -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.avi" -o -iname "*.mov" -o -iname "*.m4v" -o -iname "*.flv" -o -iname "*.wmv" -o -iname "*.webm" \) -print0)

show_stats
