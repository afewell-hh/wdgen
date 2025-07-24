#!/bin/bash

# CSV to YAML Converter for Kubernetes-style Objects
# Converts CSV records to YAML objects based on templates
# Author: Cloud Native DevOps Utility
# Version: 1.0.0

set -euo pipefail  # Exit on error, undefined variables, pipe failures

# Color codes for better UX
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly OUTPUT_DIR="${SCRIPT_DIR}/output"
readonly TEMPLATE_DIR="${SCRIPT_DIR}/cr_templates"

# Function to print colored output
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Function to display usage
usage() {
    cat << EOF
Usage: $(basename "$0") -t TYPE -i INPUT_FILE [-o OUTPUT_DIR] [-h]

Cloud Native CSV to YAML Converter

Converts CSV records into Kubernetes-style YAML objects based on templates.

OPTIONS:
    -t TYPE         Object type (server, connection_unbundled, connection_fabric, vpcattachment)
    -i INPUT_FILE   Path to input CSV file
    -o OUTPUT_DIR   Output directory (default: ./output)
    -h              Display this help message

EXAMPLES:
    $(basename "$0") -t server -i servers.csv
    $(basename "$0") -t server -i /path/to/servers.csv -o /custom/output

SUPPORTED TYPES:
    - server: Converts server CSV records to Server YAML objects
    - connection_fabric: Groups fabric connection CSV records by connection_name into Connection YAML objects
    - connection_unbundled: Converts unbundled connection CSV records (1:1) to Connection YAML objects
    - vpcattachment: Converts VPC attachment CSV records (1:1) to VPCAttachment YAML objects

EOF
}

# Function to validate input file
validate_input_file() {
    local input_file="$1"
    
    if [[ ! -f "$input_file" ]]; then
        print_error "Input file not found: $input_file"
        return 1
    fi
    
    if [[ ! -r "$input_file" ]]; then
        print_error "Input file is not readable: $input_file"
        return 1
    fi
    
    if [[ ! -s "$input_file" ]]; then
        print_error "Input file is empty: $input_file"
        return 1
    fi
    
    return 0
}

# Function to validate template exists
validate_template() {
    local type="$1"
    local template_file="${TEMPLATE_DIR}/${type}.yaml"
    
    if [[ ! -f "$template_file" ]]; then
        print_error "Template not found for type '$type': $template_file"
        return 1
    fi
    
    return 0
}

# Function to create output directory if it doesn't exist
ensure_output_dir() {
    local dir="$1"
    
    if [[ ! -d "$dir" ]]; then
        print_info "Creating output directory: $dir"
        mkdir -p "$dir" || {
            print_error "Failed to create output directory: $dir"
            return 1
        }
    fi
    
    return 0
}

# Function to generate timestamp
generate_timestamp() {
    date +"%Y-%m-%d-%H-%M-%S"
}

# Function to process server type CSV
process_server_csv() {
    local input_file="$1"
    local output_file="$2"
    local template_file="${TEMPLATE_DIR}/server.yaml"
    
    # Read the template
    local template
    template=$(cat "$template_file")
    
    # Initialize counters
    local count=0
    local first=true
    
    # Create or truncate output file
    : > "$output_file"
    
    print_info "Processing server objects from: $(basename "$input_file")"
    
    # Process CSV file (skip header)
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Extract name from CSV line
        name=$(echo "$line" | cut -d',' -f1)
        # Skip header line
        if [[ "$name" == "name" ]]; then
            continue
        fi
        
        # Trim whitespace
        name=$(echo "$name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        # Skip empty lines
        if [[ -z "$name" ]]; then
            continue
        fi
        
        # Add separator between objects (except for the first one)
        if [[ "$first" == true ]]; then
            first=false
        else
            echo "---" >> "$output_file"
        fi
        
        # Replace placeholders in template
        echo "$template" | sed "s/\\\$(name)/$name/g" >> "$output_file"
        
        ((count++))
        
        # Progress indicator
        if (( count % 10 == 0 )); then
            print_info "Processed $count objects..."
        fi
        
    done < "$input_file"
    
    print_success "Generated $count server objects"
    return 0
}

# Function to process connection_fabric type CSV
process_connection_fabric_csv() {
    local input_file="$1"
    local output_file="$2"
    
    # Associative array to group records by connection_name
    declare -A connection_groups
    declare -A connection_records
    
    print_info "Processing connection_fabric objects from: $(basename "$input_file")"
    
    # First pass: Read CSV and group by connection_name
    local header_skipped=false
    while IFS=',' read -r label spine_port leaf_port connection_name || [[ -n "$label" ]]; do
        # Skip header line
        if [[ "$header_skipped" == false ]]; then
            header_skipped=true
            continue
        fi
        
        # Trim whitespace from all fields
        label=$(echo "$label" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        spine_port=$(echo "$spine_port" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        leaf_port=$(echo "$leaf_port" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        connection_name=$(echo "$connection_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        # Skip empty lines
        if [[ -z "$connection_name" ]]; then
            continue
        fi
        
        # Append record to the group
        if [[ -n "${connection_groups[$connection_name]+x}" ]]; then
            connection_groups[$connection_name]="${connection_groups[$connection_name]}|${spine_port}:${leaf_port}"
        else
            connection_groups[$connection_name]="${spine_port}:${leaf_port}"
        fi
        
    done < "$input_file"
    
    # Second pass: Generate YAML for each connection group
    local count=0
    local first=true
    
    # Create or truncate output file
    : > "$output_file"
    
    # Sort connection names for consistent output
    local sorted_connections
    sorted_connections=$(printf '%s\n' "${!connection_groups[@]}" | sort)
    
    while IFS= read -r conn_name; do
        [[ -z "$conn_name" ]] && continue
        
        # Add separator between objects (except for the first one)
        if [[ "$first" == true ]]; then
            first=false
        else
            echo "---" >> "$output_file"
        fi
        
        # Write YAML header
        cat >> "$output_file" << EOF
apiVersion: wiring.githedgehog.com/v1beta1
kind: Connection
metadata:
  name: $conn_name
spec:
  fabric:
    links:
EOF
        
        # Process each link for this connection
        IFS='|' read -ra links <<< "${connection_groups[$conn_name]}"
        for link in "${links[@]}"; do
            IFS=':' read -r spine_port leaf_port <<< "$link"
            
            # Add quotes around port values
            cat >> "$output_file" << EOF
    - leaf:
        port: "$leaf_port"
      spine:
        port: "$spine_port"
EOF
        done
        
        ((count++))
        
        # Progress indicator
        if (( count % 10 == 0 )); then
            print_info "Processed $count connection groups..."
        fi
        
    done <<< "$sorted_connections"
    
    print_success "Generated $count connection_fabric objects"
    return 0
}

# Function to process connection_unbundled type CSV
process_connection_unbundled_csv() {
    local input_file="$1"
    local output_file="$2"
    
    # Initialize counters
    local count=0
    local first=true
    
    # Create or truncate output file
    : > "$output_file"
    
    print_info "Processing connection_unbundled objects from: $(basename "$input_file")"
    
    # Process CSV file (skip header)
    local header_skipped=false
    while IFS=',' read -r label server_port leaf_port connection_name || [[ -n "$label" ]]; do
        # Skip header line
        if [[ "$header_skipped" == false ]]; then
            header_skipped=true
            continue
        fi
        
        # Trim whitespace from all fields
        label=$(echo "$label" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        server_port=$(echo "$server_port" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        leaf_port=$(echo "$leaf_port" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        connection_name=$(echo "$connection_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        # Skip empty lines
        if [[ -z "$connection_name" ]]; then
            continue
        fi
        
        # Add separator between objects (except for the first one)
        if [[ "$first" == true ]]; then
            first=false
        else
            echo "---" >> "$output_file"
        fi
        
        # Write YAML object
        cat >> "$output_file" << EOF
apiVersion: wiring.githedgehog.com/v1beta1
kind: Connection
metadata:
  name: $connection_name
spec:
  unbundled:
    link:
      server:
        port: $server_port
      switch:
        port: $leaf_port
EOF
        
        ((count++))
        
        # Progress indicator
        if (( count % 10 == 0 )); then
            print_info "Processed $count objects..."
        fi
        
    done < "$input_file"
    
    print_success "Generated $count connection_unbundled objects"
    return 0
}

# Function to process vpcattachment type CSV
process_vpcattachment_csv() {
    local input_file="$1"
    local output_file="$2"
    local template_file="${TEMPLATE_DIR}/vpcattachment.yaml"
    
    # Read the template
    local template
    template=$(cat "$template_file")
    
    # Initialize counters
    local count=0
    local first=true
    
    # Create or truncate output file
    : > "$output_file"
    
    print_info "Processing vpcattachment objects from: $(basename "$input_file")"
    
    # Read all lines except header into array
    mapfile -t lines < <(tail -n +2 "$input_file")
    
    for line in "${lines[@]}"; do
        # Skip empty lines
        [[ -z "$line" ]] && continue
        
        # Parse CSV fields: attachment_name,connection,subnet
        attachment_name=$(echo "$line" | cut -d',' -f1)
        connection=$(echo "$line" | cut -d',' -f2)
        subnet=$(echo "$line" | cut -d',' -f3)
        
        # Trim whitespace from all fields
        attachment_name=$(echo "$attachment_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        connection=$(echo "$connection" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        subnet=$(echo "$subnet" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        # Skip if attachment_name is empty
        [[ -z "$attachment_name" ]] && continue
        
        # Add separator between objects (except for the first one)
        if [[ "$first" == true ]]; then
            first=false
        else
            echo "---" >> "$output_file"
        fi
        
        # Replace placeholders in template
        echo "$template" | sed "s|\\\$(attachment_name)|$attachment_name|g" | sed "s|\\\$(connection)|$connection|g" | sed "s|\\\$(subnet)|$subnet|g" >> "$output_file"
        
        count=$((count + 1))
        
        # Progress indicator
        if (( count % 10 == 0 )); then
            print_info "Processed $count objects..."
        fi
    done
    
    print_success "Generated $count vpcattachment objects"
    return 0
}

# Main function
main() {
    local object_type=""
    local input_file=""
    local output_dir="$OUTPUT_DIR"
    
    # Parse command line arguments
    while getopts "t:i:o:h" opt; do
        case ${opt} in
            t )
                object_type="$OPTARG"
                ;;
            i )
                input_file="$OPTARG"
                ;;
            o )
                output_dir="$OPTARG"
                ;;
            h )
                usage
                exit 0
                ;;
            \? )
                print_error "Invalid option: -$OPTARG"
                usage
                exit 1
                ;;
            : )
                print_error "Option -$OPTARG requires an argument"
                usage
                exit 1
                ;;
        esac
    done
    
    # Validate required arguments
    if [[ -z "$object_type" ]] || [[ -z "$input_file" ]]; then
        print_error "Missing required arguments"
        usage
        exit 1
    fi
    
    # Validate object type
    case "$object_type" in
        server|connection_fabric|connection_unbundled|vpcattachment)
            ;;
        *)
            print_error "Invalid object type: $object_type"
            print_info "Supported types: server, connection_unbundled, connection_fabric, vpcattachment"
            exit 1
            ;;
    esac
    
    # Validate input file
    validate_input_file "$input_file" || exit 1
    
    # Validate template exists
    validate_template "$object_type" || exit 1
    
    # Ensure output directory exists
    ensure_output_dir "$output_dir" || exit 1
    
    # Generate output filename with timestamp
    local timestamp
    timestamp=$(generate_timestamp)
    local output_file="${output_dir}/${object_type}s_${timestamp}.yaml"
    
    print_info "Starting CSV to YAML conversion"
    print_info "Type: $object_type"
    print_info "Input: $input_file"
    print_info "Output: $output_file"
    
    # Process based on object type
    case "$object_type" in
        server)
            process_server_csv "$input_file" "$output_file"
            ;;
        connection_fabric)
            process_connection_fabric_csv "$input_file" "$output_file"
            ;;
        connection_unbundled)
            process_connection_unbundled_csv "$input_file" "$output_file"
            ;;
        vpcattachment)
            process_vpcattachment_csv "$input_file" "$output_file"
            ;;
    esac
    
    # Verify output was created
    if [[ -f "$output_file" ]] && [[ -s "$output_file" ]]; then
        print_success "YAML file generated successfully: $output_file"
        print_info "File size: $(wc -c < "$output_file") bytes"
        print_info "Object count: $(grep -c "^kind:" "$output_file" || true)"
    else
        print_error "Failed to generate output file"
        exit 1
    fi
}

# Run main function
main "$@"