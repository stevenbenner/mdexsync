#!/bin/bash
# MangaDex Sync Tool
# A script to download the specified work from MangaDex and keep the
# content sychronized with the latest versions on subsequent runs.
#
# Copyright 2024 Steven Benner
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

declare -r PROGRAM_NAME='mdexsync'
declare -rl API_URL='https://api.mangadex.org'
declare -ri MAX_RETRY=5

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
		  -m NUM   Maximum number of chapters to download.
		  -h       Print this usage and quit.

		EXAMPLES
		Download first 5 chapters of Yotsuba&! to the ~/Downloads folder:
		  ${0##*/} -p ~/Downloads -i 58be6aa6-06cb-4ca5-bd20-f1392ce451fb -m 5

		Report bugs to <https://github.com/stevenbenner/mdexsync>.
EOF
	exit
}

# handle script options
declare manga_id='' download_path=''
declare -i download_limit=0
while getopts 'hm:i:p:' arg; do
	case ${arg} in
		i) manga_id=${OPTARG} ;;
		p) download_path=${OPTARG%/} ;;
		m) download_limit=${OPTARG} ;;
		*) usage ;;
	esac
done
: "${manga_id:?Missing -i option! Run \'${0##*/} -h\' for help.}"
: "${download_path:?Missing -p option! Run \'${0##*/} -h\' for help.}"
# +1 download limit to avoid a "download_limit_set" variable, just break on 1 instead of 0
(( download_limit )) && download_limit=${download_limit}+1

get_title() {
	local manga_url
	manga_url="${API_URL}/manga/${1}"
	curl --fail --no-progress-meter "${manga_url}" | \
		jq --raw-output '.data.attributes.title.en'
}

get_chapters() {
	local feed_url feed_params filter
	feed_url="${API_URL}/manga/${1}/feed"
	feed_params=(
		'translatedLanguage[]=en'
		'order[chapter]=asc'
		'order[volume]=asc'
		'includes[]=scanlation_group'
		'limit=500'
	)

	# select only the .data[] array content
	filter='.data[]'
	# select only chapters not provided by an official scanlation group
	# (official releases are linked to other sites and cannot be downloaded by this script)
	filter+='| select(any(.relationships[]; .type == "scanlation_group" and .attributes.official == true) | not)'
	# construct the final list of data - a list of arrays with the following elements:
	#   col 1: chapter number
	#   col 2: chapter ID
	#   col 3: chapter version
	#   col 4: chapter title
	#   col 5..n: scanlation group name (chapter releases can have multiple associated groups)
	filter+='| [
		.attributes.chapter,
		.id,
		.attributes.version,
		.attributes.title,
		(.relationships[] | select(.type == "scanlation_group") | .attributes.name)
	]'
	# format the data as a tab-separated list for processing in this script
	filter+='| join("\t")'

	curl --fail --no-progress-meter --globoff "${feed_url}?$(printf '%s&' "${feed_params[@]}")" | \
		jq --raw-output "${filter}"
}

get_pages() {
	local pages_url
	pages_url="${API_URL}/at-home/server/${1}"
	curl --fail --no-progress-meter "${pages_url}" | \
		jq --raw-output '.baseUrl + "/data/" + .chapter.hash + "/" + .chapter.data[]'
}

save_page() {
	local page_number file_name file_extension file_path retry
	printf -v page_number '%03d' "${2}"
	file_name=$(basename -- "${1}")
	file_extension="${file_name##*.}"
	file_path="${3}/${page_number}.${file_extension}"
	echo "Downloading page ${2}..."
	if ! curl --fail --output "${file_path}" "${1}"; then
		retry="${4}"
		if [[ $((--retry)) -gt 0 ]]; then
			echo "Failed to save page ${2}. Retrying..."
			echo "${1}"
			sleep "$(bc <<< "scale=1; (${MAX_RETRY} / ${retry}) * 3")"
			save_page "${1}" "${2}" "${3}" ${retry}
		else
			echo "Failed to save page ${2}. Giving up."
			exit 2
		fi
	fi
}

cache_title() {
	local cache_path manga_index_path entry
	cache_path="${XDG_CACHE_HOME:-$HOME/.cache}/${PROGRAM_NAME}"
	manga_index_path="${cache_path}/manga_index"

	# try to fetch the title from the index based on the ID
	if [[ -f "${manga_index_path}" ]]; then
		while read -r entry; do
			if [[ $(cut -f1 <<< "${entry}") = "${1}" ]]; then
				printf '%s' "$(cut -f2 <<< "${entry}")"
				return
			fi
		done < "${manga_index_path}"
	fi

	# if we made it this far then there was no title in the index, so add it
	mkdir --parents "${cache_path}"
	echo "${1}	${2}" >> "${manga_index_path}"
	printf '%s' "${2}"
}

sanatize_path() {
	local str
	str="${1}"
	str="${str//\//⧸}" # replace slashes with unicode U+29F8 BIG SOLIDUS
	printf '%s' "${str}"
}

get_chapter_path() {
	local chapter_number chapter_title version groups number_major number_minor
	chapter_number=$(cut -f1 <<< "${1}")
	version=$(cut -f3 <<< "${1}")
	chapter_title=$(cut -f4 <<< "${1}")
	groups=$(cut -f5- <<< "${1}" | sed 's/\t/ \& /g') # concat multiple groups with ampersand
	if [[ -z ${groups} ]]; then
		groups='no group'
	fi
	IFS=. read -r number_major number_minor <<< "${chapter_number}" # split decimal
	if [[ -n ${chapter_title} ]]; then
		printf '%s/%s/c%03d.%dv%d [%s] %s\n' \
			"${download_path}" \
			"$(sanatize_path "${title}")" \
			"${number_major}" \
			"${number_minor}" \
			"${version}" \
			"$(sanatize_path "${groups}")" \
			"$(sanatize_path "${chapter_title}")"
	else
		printf '%s/%s/c%03d.%dv%d [%s]\n' \
			"${download_path}" \
			"$(sanatize_path "${title}")" \
			"${number_major}" \
			"${number_minor}" \
			"${version}" \
			"$(sanatize_path "${groups}")"
	fi
}

download_chapter() {
	local chapter_number chapter_id path temp_dir page_num
	chapter_number=$(cut -f1 <<< "${1}")
	path="$(get_chapter_path "${1}")"

	# skip anything that we already have
	if [[ -d ${path} ]]; then
		echo "Skipping chapter ${chapter_number}. Directory already exists."
		return
	fi

	echo "Downloading chapter ${chapter_number}..."

	# page download loop
	chapter_id=$(cut -f2 <<< "${1}")
	temp_dir=$(mktemp --directory)
	page_num=1
	while read -r page; do
		save_page "${page}" ${page_num} "${temp_dir}" ${MAX_RETRY}
		: $((page_num++))
		sleep 0.2
	done <<< "$(get_pages "${chapter_id}")"

	# move files to their destination and clean up
	if ! mkdir --parents "${path}"; then
		echo "Failed to create directory '${path}'!"
		exit 1
	fi
	mv "${temp_dir}"/* "${path}"
	rm --recursive "${temp_dir}"
}

# get title and make sure the provided ID is a valid target
title=$(get_title "${manga_id}")
if [[ -z ${title} ]]; then
	echo "Failed to get ${manga_id}."
	exit 1;
fi

# pull the title from the saved index, or save the title if it isn't indexed
title=$(cache_title "${manga_id}" "${title}")

echo "Downloading '${title}'..."

# main download loop
while read -r chapter; do
	if (( download_limit )) && [[ $((download_limit--)) -eq 1 ]]; then
		break
	fi
	download_chapter "${chapter}"
done <<< "$(get_chapters "${manga_id}")"

echo "Done."
echo "MangaDex URL: <https://mangadex.org/title/${manga_id}>"
