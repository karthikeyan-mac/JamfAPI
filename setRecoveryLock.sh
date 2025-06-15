#!/bin/zsh

# Script to Set/Remove Recovery Lock on Apple Silicon Macs using the Jamf API.
# Works based on the 'lockMode' variable (Set/Remove) to configure Recovery Lock.
# 
# Key Functionalities:
# - Retrieves the Mac's serial number.
# - Generates a 26-digit random Recovery Lock password.
# - Uses JAMF API Roles and Clients
# - Uses Jamf Pro API to:
#   - Obtain access token
#   - Fetch the computer's management ID
#   - Send the Set Recovery Lock MDM command based on 'lockMode'
# - If 'lockMode' is "Set", it enables Recovery Lock with a generated password.
# - If 'lockMode' is "Remove", it clears the Recovery Lock.
# - Finally, invalidates the API token for security.
# 
# Requirements:
# - A Mac with Apple Silicon running macOS 11.5 or later.
# - Jamf Pro API permissions: 
#   - Send Set Recovery Lock Command
#   - View MDM Command Information
#   - Read Computers
#   - View Recovery Lock
#
# Usage:
# - Provide 'Set' or 'Remove' as parameter 4 in a Jamf policy.
# - For details, refer: 
#   https://learn.jamf.com/en-US/bundle/technical-articles/page/Recovery_Lock_Enablement_in_macOS_Using_the_Jamf_Pro_API.html
# 
#  Karthikeyan Marappan

Jamf_URL="https://karthikeyan.jamfcloud.com/"
Jamf_URL=${Jamf_URL%%/}
#echo "Jamf URL: $Jamf_URL"
client_id="2mffafd160-413b-4184-be97-dssc4c40183ff"
client_secret="ddi8WBB6sEtdV5e2oGGsssdddfcnwlE7yYUb8W7IiwRftyMirPZSnttMH5utuUmsS"
current_epoch=$(date +%s)
#$4=="Set"
lockMode="Set"
serialNumber=$(system_profiler SPHardwareDataType | awk '/Serial/ {print $4}')
random_number=$(printf "%d%05d%05d%05d%05d%05d" $((RANDOM % 10)) $RANDOM $RANDOM $RANDOM $RANDOM $RANDOM)

getAccessToken() {
	response=$(curl --silent --location --request POST "${Jamf_URL}/api/oauth/token" \
		--header "Content-Type: application/x-www-form-urlencoded" \
		--data-urlencode "client_id=${client_id}" \
		--data-urlencode "grant_type=client_credentials" \
		--data-urlencode "client_secret=${client_secret}")
	if [[ -z "$response" ]]; then
		echo "Check Jamf URL"
		exit 1
	elif [[ "$response" == '{"error":"invalid_client"}' ]]; then
		echo "Check the API Client roles"
		exit 1
	fi
	access_token=$(echo "$response" | plutil -extract access_token raw -)
	token_expires_in=$(echo "$response" | plutil -extract expires_in raw -)
	token_expiration_epoch=$((current_epoch + token_expires_in - 1))
}

invalidateToken() {
	responseCode=$(curl -w "%{http_code}" -H "Authorization: Bearer ${access_token}" \
		"${Jamf_URL}/api/v1/auth/invalidate-token" -X POST -s -o /dev/null)
	if [[ $responseCode == 204 ]]; then
		echo "Token successfully invalidated"
	elif [[ $responseCode == 401 ]]; then
		echo "Token already invalid"
	else
		echo "Unexpected response code: $responseCode"
		exit 1  # Or handle it in a different way (e.g., retry or log the error)
	fi
	
}

getManagementId() {
	inventoryResponse=$(curl --silent --location --request GET "${Jamf_URL}/api/v1/computers-inventory?section=GENERAL&filter=hardware.serialNumber==$serialNumber" \
		--header "Authorization: Bearer ${access_token}")
	
	managementID=$(echo "$inventoryResponse" | jq -r '.results[0].general.managementId')
	[[ -z "$managementID" || "$managementID" == "null" ]] && { echo "Failed to retrieve management ID. Check if API Client has required permission or serial number matches in Jamf"; exit 1; }
}

sendRecoveryLockCommand() {
	local newPassword="$1"
	
	responseCode=$(curl -w "%{http_code}" "$Jamf_URL/api/v2/mdm/commands" \
		-H "accept: application/json" \
		-H "Authorization: Bearer ${access_token}"  \
		-H "Content-Type: application/json" \
		-X POST -s -o /dev/null \
		-d @- <<EOF
		{
			"clientData": [{ "managementId": "$managementID", "clientType": "COMPUTER" }],
			"commandData": { "commandType": "SET_RECOVERY_LOCK", "newPassword": "$newPassword" }
		}
EOF
	)
	
	echo "Recovery Lock ${lockMode} for ${serialNumber}"
}

main() {
	getAccessToken
	getManagementId
	
	if [[ $lockMode == "Set" ]]; then
		sendRecoveryLockCommand "$random_number"
	elif [[ $lockMode == "Remove" ]]; then
		sendRecoveryLockCommand ""
	else
		echo "Invalid parameter: Use 'Set' or 'Remove'"
		exit 1
	fi
	invalidateToken
}

main