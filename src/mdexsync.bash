#!/bin/bash
# MangaDex Sync Tool
# A script to download the specified work from MangaDex and keep the
# content synchronized with the latest versions on subsequent runs.
#
# Copyright 2025 Steven Benner
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

declare -r program_name='mdexsync'
declare -r index_filename='manga_index'
declare -rl api_url='https://api.mangadex.org'

usage() {
	cat <<- EOF
		Usage: ${0##*/} [OPTION]...
		Download content from MangaDex.

		This program will create a directory with the title of the manga in the
		specified download folder. Then it will create a subdirectory for each
		chapter containing the downloaded page images.

		You will need the ID of the manga that you wish to download. You can
		get the ID from the URL used for the work on mangadex.org. It will be a
		hexadecimal GUID in the format '88888888-8888-8888-8888-888888888888'.

		OPTIONS
		  -p DIR   Path to directory where downloaded content should be saved.
		  -i ID    ID of the work to download.
		  -m NUM   Maximum number of chapters to download. Unlimited if omitted.
		  -v       Print verbose output.
		  -h       Print this usage and quit.

		EXAMPLES
		Download first 5 chapters of Yotsuba&! to the ~/Downloads folder:
		  ${0##*/} -p ~/Downloads -i 58be6aa6-06cb-4ca5-bd20-f1392ce451fb -m 5

		Report bugs to <https://github.com/stevenbenner/mdexsync>.
EOF
	exit
}

err() {
	echo "${1}" >&2
	exit 1
}

# check dependencies
for dep in curl diff jq; do
	[[ $(command -v "${dep}" 2> /dev/null) ]] || err "Missing dependency: ${dep}"
done

# handle script options
declare manga_id='' download_path=''
declare -i download_limit=0 verbose=0
while getopts 'hvm:i:p:' arg; do
	case ${arg} in
		i) manga_id=${OPTARG} ;;
		p) download_path=${OPTARG%/} ;;
		m) download_limit=${OPTARG} ;;
		v) verbose=1 ;;
		*) usage ;;
	esac
done
[[ -z ${manga_id} ]] && err "Missing -i option! Run '${0##*/} -h' for help."
[[ -z ${download_path} ]] && err "Missing -p option! Run '${0##*/} -h' for help."
# +1 download limit to avoid a "download_limit_set" variable, just break on 1 instead of 0
(( download_limit )) && download_limit=${download_limit}+1

get_title() {
	local manga_url="${api_url}/manga/${1}"
	curl --fail --no-progress-meter -- "${manga_url}" | \
		jq --raw-output '.data.attributes.title.en'
}

get_chapters() {
	local feed_url="${api_url}/manga/${1}/feed"
	local feed_params=(
		'translatedLanguage[]=en'
		'order[chapter]=asc'
		'order[volume]=asc'
		'includes[]=scanlation_group'
		'includes[]=user'
		'limit=500'
	)

	# select only the .data[] array content
	local filter='.data[]'
	# select only chapters not provided by an official scanlation group
	# (official releases are linked to other sites and cannot be downloaded by this script)
	filter+='| select(any(.relationships[]; .type == "scanlation_group" and .attributes.official == true) | not)'
	# construct the final list of data - a list of arrays with the following elements:
	#   col 1: chapter number
	#   col 2: chapter ID
	#   col 3: chapter version
	#   col 4: chapter title
	#   col 5: uploader username
	#   col 6..n: scanlation group name (chapters can have multiple associated groups)
	filter+='| [
		.attributes.chapter,
		.id,
		.attributes.version,
		.attributes.title,
		(.relationships[] | select(.type == "user") | .attributes.username),
		(.relationships[] | select(.type == "scanlation_group") | .attributes.name)
	]'
	# format the data as a tab-separated list for processing in this script
	filter+='| join("\t")'

	curl --fail --no-progress-meter --globoff -- "${feed_url}?$(printf '%s&' "${feed_params[@]}")" | \
		jq --raw-output "${filter}"
}

get_pages() {
	local pages_url="${api_url}/at-home/server/${1}"
	curl --fail --no-progress-meter -- "${pages_url}" | \
		jq --raw-output '.baseUrl + "/data/" + .chapter.hash + "/" + .chapter.data[]'
}

cache_title() {
	local cache_path="${XDG_DATA_HOME:-$HOME/.local/share}/${program_name}"
	local index_path="${cache_path}/${index_filename}"

	# version 1.0 put this file in the $XDG_CACHE_HOME, so relocate it if found
	local old_cache_path="${XDG_CACHE_HOME:-$HOME/.cache}/${program_name}"
	local old_index_path="${old_cache_path}/${index_filename}"
	if [[ -f ${old_index_path}  ]] && [[ ! -e ${index_path} ]]; then
		mkdir --parents "${cache_path}"
		mv "${old_index_path}" "${index_path}"
		rmdir "${old_cache_path}"
	fi

	# try to fetch the title from the index based on the ID
	if [[ -f "${index_path}" ]]; then
		local -a cache_entry
		while read -r; do
			readarray -d $'\t' -t cache_entry < <(printf '%s' "${REPLY}")
			if [[ ${cache_entry[0]} = "${1}" ]]; then
				printf '%s' "${cache_entry[1]}"
				return
			fi
		done < "${index_path}"
	fi

	# if we made it this far then there was no title in the index, so add it
	mkdir --parents "${cache_path}"
	echo "${1}	${2}" >> "${index_path}"
	printf '%s' "${2}"
}

sanatize_path() {
	local LC_CTYPE=C
	local str="${1}"
	str="${str//\//⧸}" # replace slashes with unicode U+29F8 BIG SOLIDUS
	str="${str#"${str%%[![:space:]]*}"}" # trim leading whitespace
	str="${str%"${str##*[![:space:]]}"}" # trim trailing whitespace
	printf '%s' "${str}"
}

sanatize_filename() {
	local str="${1}"
	str="$(sanatize_path "${str}")"
	str="${str#"${str%%[!.]*}"}" # trim leading dots
	printf '%s' "${str}"
}

get_chapter_path() {
	local -a chapter
	readarray -d $'\t' -t chapter < <(printf '%s' "${1}")
	local chapter_number=${chapter[0]}
	local chapter_version=${chapter[2]}
	local chapter_title=${chapter[3]}
	local chapter_uploader=${chapter[4]}

	# build attribution tag
	local -i i
	local groups=''
	for (( i=5; i<${#chapter[@]}; i++ )); do
		# concat multiple groups with ampersand
		groups+=" & $(sanatize_path "${chapter[$i]}")"
	done
	groups=${groups:3} # trim leading space-amp-space, if present
	if [[ -z ${groups} ]]; then
		# if there were no associated groups then tag with username
		groups="$(sanatize_path "${chapter_uploader}")"
	fi

	# split chapter number decimal
	local -i number_major number_minor
	IFS=. read -r number_major number_minor <<< "${chapter_number}"

	# build path and output
	local chapter_path
	printf -v chapter_path '%s/%s/c%03d.%dv%d [%s]' \
		"${download_path}" \
		"$(sanatize_filename "${title}")" \
		"${number_major}" \
		"${number_minor}" \
		"${chapter_version}" \
		"${groups}"
	if [[ -n ${chapter_title} ]]; then
		chapter_path+=" $(sanatize_path "${chapter_title}")"
	fi
	printf '%s' "${chapter_path}"
}

download_chapter() {
	local -a chapter page_urls page_paths
	local chapter_number chapter_id chapter_version path temp_dir

	readarray -d $'\t' -t chapter < <(printf '%s' "${1}")
	chapter_number=${chapter[0]}
	chapter_id=${chapter[1]}
	chapter_version=${chapter[2]}
	path="$(get_chapter_path "${1}")"

	# skip anything that we already have
	if [[ -d ${path} ]]; then
		((verbose)) && echo "Skipping chapter ${chapter_number}. Directory already exists."
		return
	fi

	echo "Downloading chapter ${chapter_number}..."

	# get page URLs and generate file paths to pass to curl
	readarray -t page_urls < <(get_pages "${chapter_id}")
	temp_dir=$(mktemp --directory --tmpdir "${program_name}.XXXXXX")
	local page_number page_url file_extension file_path
	local -i page_num
	for (( page_num=0; page_num<${#page_urls[@]}; page_num++ )); do
		printf -v page_number '%03d' $((page_num+1))
		page_url=${page_urls[$page_num]}
		file_extension="${page_url##*.}"
		if [[ ${file_extension} =~ [^a-zA-Z] ]]; then
			err "Found invalid image file extension '${file_extension}'. Aborting."
		fi
		file_path="${temp_dir}/${page_number}.${file_extension}"
		page_paths+=('--output')
		page_paths+=("${file_path}")
	done

	# download the pages
	if ! curl \
		--rate 5/s \
		--retry-max-time 60 \
		--retry-connrefused \
		--fail-early \
		"${page_paths[@]}" -- "${page_urls[@]}"
	then
		rm --recursive "${temp_dir}"
		err "Failed to download all pages for chapter ${chapter_number}. Giving up."
	fi

	# handle version bumps without content changes
	# if we have a previous version of the chapter then check to see if the new
	# version is identical - if it is then update the existing version number
	if [[ $chapter_version -gt 1 ]]; then
		local -i i
		local oldversion_chapter oldversion_path
		for (( i=chapter_version-1; i>0; i-- )); do
			chapter[2]=${i}
			printf -v oldversion_chapter '%s\t' "${chapter[@]}"
			oldversion_chapter=${oldversion_chapter%?}
			oldversion_path="$(get_chapter_path "${oldversion_chapter[@]}")"
			if [[ -d ${oldversion_path} ]] && diff "${oldversion_path}" "${temp_dir}" > /dev/null 2>&1; then
				echo "Chapter ${chapter_number} version ${chapter_version} content is identical to existing v${i}. Renaming existing directory to v${chapter_version}."
				rm --recursive "${temp_dir}"
				if ! mv -- "${oldversion_path}" "${path}"; then
					err "Failed to rename directory '${oldversion_path}' to '${path}'!"
				fi
				return
			fi
		done
	fi

	# move files to their destination and clean up
	if mkdir --parents -- "${path}"; then
		mv -- "${temp_dir}"/* "${path}"
		rm --recursive "${temp_dir}"
	else
		rm --recursive "${temp_dir}"
		err "Failed to create directory '${path}'!"
	fi
}

# get title and make sure the provided ID is a valid target
title=$(get_title "${manga_id}")
[[ -z ${title} ]] && err "Failed to get ${manga_id}."

# pull the title from the saved index, or save the title if it isn't indexed
title=$(cache_title "${manga_id}" "${title}")

echo "Downloading '${title}'..."

# main download loop
while read -r chapter; do
	if [[ -z ${chapter} ]]; then
		echo "No downloadable chapter."
		continue
	fi
	if (( download_limit )) && [[ $((download_limit--)) -eq 1 ]]; then
		break
	fi
	download_chapter "${chapter}"
done <<< "$(get_chapters "${manga_id}")"

((verbose)) && echo "Done."
((verbose)) && echo "MangaDex URL: <https://mangadex.org/title/${manga_id}>"
