#!/bin/bash
#
# Script to update (add/remove) the existing Computer Static Group from the list of serial numbers.
# ADD will append the existing static group
# Karthikeyan Marappan
# API Role Privileges: Update Static Computer Groups

###################### CONFIGURABLE VARIABLES ################################
serialNumberList="$HOME/Desktop/sourceList.txt"     # Path to plain text file with serial numbers
Jamf_URL="https://karthikeyan.jamfcloud.com"        # Your Jamf Pro URL
Jamf_URL="${Jamf_URL%/}"                            # Remove trailing slash if present
client_id="z1bb0a9b-888e-4ae4-88zX-9t402M0402"      # Jamf API Client ID
client_secret="AAAxcz6PSynqyyuPfNdY4280i5cgQ3Mq"    # Jamf API Client Secret 
staticGroupID=581                                   # Static Group ID
actionRequired="ADD"                                # Set to "ADD" to add devices or "REMOVE" to remove them
logFile="/tmp/jamf_static_group.log"                # Log file location
#############################################################################

countSuccess=0
countFailure=0
successSerial=()

# Ensure log file exists
touch "$logFile"

log() {
    echo "$(date +"%Y-%m-%d %H:%M:%S") - $1" | tee -a "$logFile"
}

# Validate required variables
if [[ -z "$Jamf_URL" || -z "$client_id" || -z "$client_secret" || -z "$staticGroupID" || -z "$actionRequired" ]]; then
    log "Error: One or more required variables are empty."
    exit 1
fi

# Validate serialNumberList file
if [[ ! -f "$serialNumberList" ]]; then
    log "Error: Source file does not exist."
    exit 1
elif [[ ! -s "$serialNumberList" ]]; then
    log "Error: Source file is empty."
    exit 1
fi

# Determine action (ADD/REMOVE)
case "$actionRequired" in
    ADD) action="computer_additions" ;;
    REMOVE) action="computer_deletions" ;;
    *)
        log "Error: actionRequired must be 'ADD' or 'REMOVE'."
        exit 1
    ;;
esac

# Function to fetch Jamf API Token
getAccessToken() {
    log "Fetching Jamf API token...from ${Jamf_URL}"
    response=$(curl --silent --fail-with-body --location --request POST "${Jamf_URL}/api/oauth/token" \
        --header "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "client_id=${client_id}" \
        --data-urlencode "grant_type=client_credentials" \
        --data-urlencode "client_secret=${client_secret}")
    
    if [[ $? -ne 0 || -z "$response" ]]; then
        log "Error: Failed to obtain access token. Check Jamf URL and credentials."
        exit 1
    fi
    access_token=$(echo "$response" | jq -r '.access_token')
    if [[ "$access_token" == "null" ]]; then
        log "Error: Invalid API client credentials. Check API Role permissions."
        exit 1
    fi
    log "Successfully obtained API token."
}

# Invalidate API Token
invalidateToken() {
    log "Invalidating API token..."
    responseCode=$(curl -w "%{http_code}" -H "Authorization: Bearer ${access_token}" \
        "${Jamf_URL}/api/v1/auth/invalidate-token" -X POST -s -o /dev/null)
    
    case "$responseCode" in
        204) log "Token successfully invalidated." ;;
        401) log "Token already invalid." ;;
        *) log "Unexpected response code during token invalidation: $responseCode" ;;
    esac
}

# Function to process a single serial number
changeStaticComputerGroup() {
    local serialNumber="$1"
    local xmlData="<computer_group><${action}><computer><serial_number>${serialNumber}</serial_number></computer></${action}></computer_group>"
    response=$(curl -s --location --request PUT "$Jamf_URL/JSSResource/computergroups/id/$staticGroupID" \
        --header "Accept: application/xml" \
        --header "Content-Type: application/xml" \
        --header "Authorization: Bearer $access_token" \
        --data-raw "$xmlData" \
        --write-out '\n%{http_code}')
    #echo $response
    http_code=$(tail -n1 <<< "$response")
    if [[ "$http_code" == 201 ]]; then
        ((countSuccess++))
        successSerial+=("$serialNumber")
        log "Successfully processed serial: $serialNumber"
    elif [[ "$http_code" == 409 ]]; then
        ((countFailure++))
        failureSerial+=("$serialNumber")
        log "Serial Number does not exists in Jamf: $serialNumber"
    elif [[ "$http_code" == 401 ]]; then
        ((countFailure++))
        failureSerial+=("$serialNumber")
        log "Unauthorized to Update Static Group. Please check API Role permissions"
        exit 1
    else
        ((countFailure++))
        failureSerial+=("$serialNumber")
        log "Error: API request failed with HTTP code $http_code for serial: $serialNumber. Please check the URL and Static Group ID"
    fi
}
processSerialNumber() {
    log "Processing serial numbers individually..."
    
    while IFS= read -r serialNumber || [[ -n "$serialNumber" ]]; do
        changeStaticComputerGroup "$serialNumber"
    done < "$serialNumberList"
    
    # Display Summary
    log "Success: $countSuccess. Serial Numbers"
    log "---------------------------------------"
    printf "%s\n" "${successSerial[@]}" | tee -a "$logFile"
    log "---------------------------------------"
    log "Failed: $countFailure. Serial Numbers"
    log "---------------------------------------"
    printf "%s\n" "${failureSerial[@]}" | tee -a "$logFile"
}

main() {
    getAccessToken
    processSerialNumber
    invalidateToken
}

main