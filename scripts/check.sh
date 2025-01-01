#!/bin/bash

echo >&2 "Beginning zpool scrub checker."

### CONFIGURATION -

# Convert the ENV string to an array:
IFS=' ' read -a POOL_NAMES <<< "$POOL_NAMES"

# Discord config.
# This webhook points to a channel that only errors will be sent to,
# so that you can observe the other channel with notifications off.
ERROR_REPORT_WEBHOOK_URL="${ERROR_REPORT_WEBHOOK_URL}"
# This points to a channel dedicated to logging everyday statuses. Both
# successes and errors will be sent here.
DISK_HEALTH_WEBHOOK_URL="${DISK_HEALTH_WEBHOOK_URL}"

# For differentiating between different devices you want reported.
DEVICE_NAME="${DEVICE_NAME}"
DEVICE_DISCORD_ICON="${DEVICE_DISCORD_ICON:-:whale:}" # Hover over the emojis to see the icon name.

discord_title=""
discord_icon=""
discord_color=""
discord_description=""

# Define keyword signifying unhealthy condtion.
unhealthy_conditions='(DEGRADED|FAULTED|OFFLINE|UNAVAIL|REMOVED|FAIL|DESTROYED|corrupt|cannot|unrecover)'
# Max number of days that any pool should have had a scrub.
scrub_expiration_days="32"
# Get date.
current_date=$(date +%s)

# Let's check if this system even has ZFS.
if [[ ! $(command -v zpool 2>&1 >/dev/null) ]]; then
    echo >&2 "zpool was not found. Exiting."
    exit 1
fi


# Iterate through the pools.
for pool_name in "${POOL_NAMES[@]}"
do


    ### DISK HEALTH -

    # Reports.
    default_report="This zpool is operating normally."
    error_report=""
    scrub_resilver_report=""
    scrub_expiration_report=""

    # Get the status of the iterated pool.
    pool_info=$(/sbin/zpool status -v "${pool_name}" 2>1&)

    ## Errors:
    # Returns blank if the pool cannot be found.
    if [[ ! "${pool_info}" ]]; then
        error_report="\n\nThis pool could not be found."
    else
        # Search for any term signifying an uhealthy condition.
        pool_condition=$(echo "${pool_info}" | egrep -i ${unhealthyConditions})

        # Search for error codes or text.
        pool_error_default_status="No known data errors"
        pool_errors=$(echo "${pool_info}" | grep ONLINE | grep -v state | awk '{print $3 $4 $5}' | grep -v 000)
        pool_error_report=$(echo "${pool_info}" | grep errors: | awk '{$1=""; print $0 }' | grep -v "${pool_error_default_status}")

        if [[ "${pool_errors}" ]] || [[ "${pool_error_report}" ]]; then
            error_report="\n\nErrors were found in the read, write or checksum fields. Run "\`"zpool list -v ${pool}"\`" for details."
        fi
    fi

    ## Scrubs:
    # Check if a scrub or resilver is in progress.
    if [[ $(echo "${pool_info}" | egrep -c "scrub in progress|resilver") > 0 ]]; then
        scrub_resilver_report="\n\nA pool scrub or resilver is currently in progress."
    elif [[ $(echo "${pool_info}" | egrep -c "scrub canceled") > 0 ]]; then
        scrub_resilver_report="\n\nA pool scrub was canceled."
    else

        # Get the last scrub date.
        pool_scrub_raw_date=$(echo "${pool_info}" | grep scrub | awk '{print $11" "$12" " $13" " $14" "$15}')
        pool_scrub_date=$(date -d "$pool_scrub_raw_date" +%s)

        # Convert expiration to seconds.
        scrub_expiration_seconds=$(expr 26 \* 60 \* 60 \* ${scrub_expiration_days})

        # Set notfication text for the last scrub.
        default_report="${default_report}\n\nLast scrub: **${pool_scrub_raw_date}**"

        # Check if next scrub date has expired.
        if [ $(($current_date - $pool_scrub_date)) -ge $scrub_expiration_seconds ]; then
            scrub_expiration_report="\n\nThis pool scrub date is overdue. Check root's cron to ensure it's scheduled."
        fi

    fi


    ### FORMAT DISCORD MESSAGE -

    # Format colors and icons.
    # There were issues.
    if [ "${error_report}" ] || [ "${scrub_expiration_report}"]; then

        discord_icon=":broken_heart:"
        discord_color="15606820" # Red
        discord_description="${error_report}${scrub_expiration_report}${scrub_resilver_report}"

    # Everything's ok.
    else

        discord_icon=":green_heart:"
        discord_color="166160" # Green
        discord_description="${default_report}${scrub_resilver_report}"

    fi

    # discord JSON formatting.
    discord_embeds='{
        "username": "Disk Health",
        "embeds": [{
            "title": "Pool '${pool_name}' (on '${DEVICE_NAME}' '${DEVICE_ICON}')",
            "description": "'${discord_icon}' '${discord_description}'",
            "color": '${discord_color}'
        }]
    }'
    curl_args='-X POST -H "Content-Type:application/json; charset=utf-8" -d '\'"${discord_embeds}"\'

    # Run any outcomes on the disk health channel.
    eval 'curl '${curl_args}' '${DISK_HEALTH_WEBHOOK_URL}

    # Also run errors on the general channel.
    if [ "${error_report}" ] || [ "${scrub_expiration_report}"]; then
        eval 'curl '${curl_args}' '${ERROR_REPORT_WEBHOOK_URL}
    fi

done

exit 0