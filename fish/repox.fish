# ~/.config/fish/functions/repo-tracker.fish

function repox -d "GitHub Repository Tracker CLI"
    
    # Configuration
    set -l db_file "$HOME/.fav_repos.json"

    # Dependency check
    for cmd in jq gh gum
        if not type -q $cmd
            set_color red; echo "Error: Required tool '$cmd' is not installed."; set_color normal
            return 1
        end
    end

    # Initialize JSON DB securely if missing
    if not test -f $db_file
        echo "[]" > $db_file
        chmod 600 $db_file
    end

    # Helper: Banner
    function __repo_tracker_banner
        gum style \
            --foreground 212 --border double --border-foreground 212 \
            --align center --width 60 --margin "1 0" --padding "0 2" \
            "📦 GitHub Repository Tracker"
    end

    # Router
    set -l cmd $argv[1]
    set -l target_repo $argv[2]

    switch "$cmd"
        case add
            if test -z "$target_repo"
                gum style --foreground 196 "Usage: repo-tracker add <owner/repo>"
                return 1
            end

            # Fetch repo details
            set -l repo_data (gum spin --spinner dot --title "Fetching metadata for $target_repo..." -- gh repo view "$target_repo" --json nameWithOwner,name,owner -q '{slug: .nameWithOwner, name: .name, username: .owner.login}' 2>/dev/null)

            if test -z "$repo_data"
                gum style --foreground 196 "Error: Repository '$target_repo' not found or inaccessible."
                return 1
            end

            set -l slug (echo "$repo_data" | jq -r '.slug')
            set -l name (echo "$repo_data" | jq -r '.name')
            set -l username (echo "$repo_data" | jq -r '.username')

            set -l exists (jq "[.[] | .slug == \"$slug\"] | any" $db_file)
            if test "$exists" = "true"
                gum style --foreground 220 "⚠️  Repository '$slug' is already being tracked."
                return 0
            end

            # Prompt for installation
            gum style --foreground 212 "Is '$slug' installed on your machine?"
            set -l install_status (gum choose "Installed" "Not installed")

            set -l is_installed "false"
            set -l local_ver "Not installed"

            if test "$install_status" = "Installed"
                set is_installed "true"
                set local_ver (gum input --placeholder "Enter your installed version (e.g., v2.4.0)")
                if test -z "$local_ver"
                    set local_ver "Unknown version"
                end
            end

            # Save to JSON
            set -l tmp_db (mktemp)
            jq --arg slug "$slug" \
               --arg name "$name" \
               --arg username "$username" \
               --argjson installed "$is_installed" \
               --arg local_ver "$local_ver" \
               '. += [{slug: $slug, name: $name, username: $username, installed: $installed, local_version: $local_ver}]' \
               $db_file > $tmp_db; and mv $tmp_db $db_file

            gum style --foreground 82 "✅ Successfully added '$slug' to your tracker!"

        case set-version
            # If no target repo is provided, launch fuzzy finder
            if test -z "$target_repo"
                set -l repo_count (jq '. | length' $db_file)
                if test "$repo_count" -eq 0
                    gum style --foreground 220 "You aren't tracking any repositories yet."
                    return 1
                end
                
                gum style --foreground 212 "Search for a repository to update:"
                # FIX: Pipe directly from jq to avoid Fish array space-joining
                set target_repo (jq -r '.[].slug' $db_file | gum filter --placeholder "Type to fuzzy search...")
                
                if test -z "$target_repo"
                    gum style --foreground 196 "Operation cancelled."
                    return 1
                end
            end

            set -l exists (jq "[.[] | .slug == \"$target_repo\"] | any" $db_file)
            if test "$exists" != "true"
                gum style --foreground 196 "Error: '$target_repo' is not in your tracker."
                return 1
            end

            gum style --foreground 212 "Update installation status for '$target_repo':"
            set -l install_status (gum choose "Installed" "Not installed")

            set -l is_installed "false"
            set -l new_ver "Not installed"

            if test "$install_status" = "Installed"
                set is_installed "true"
                set new_ver (gum input --placeholder "Enter updated version (e.g., v2.5.0)")
                if test -z "$new_ver"
                    set new_ver "Unknown version"
                end
            end

            set -l tmp_db (mktemp)
            jq --arg slug "$target_repo" --arg ver "$new_ver" --argjson inst "$is_installed" \
               'map(if .slug == $slug then .local_version = $ver | .installed = $inst else . end)' \
               $db_file > $tmp_db; and mv $tmp_db $db_file

            gum style --foreground 82 "🎉 Updated '$target_repo' status successfully."

        case releases list
            set -l count (jq '. | length' $db_file)
            if test "$count" -eq 0
                gum style --foreground 220 "You aren't tracking any repositories yet."
                echo "Use 'repo-tracker add <owner/repo>' to start."
                return 0
            end

            __repo_tracker_banner

            gum style --foreground 212 "Select repositories to fetch (Tab to multi-select, Enter to confirm):"
            
            # FIX: Pipe directly from jq to gum filter to keep newlines intact
            set -l selected_slugs (jq -r '.[].slug' $db_file | gum filter --no-limit --placeholder "Type to fuzzy search... (Tab for multiple)")

            # If user presses Esc or selects nothing
            if test -z "$selected_slugs"
                gum style --foreground 196 "No repositories selected."
                return 0
            end

            # Create Markdown Table File
            set -l tmp_md (mktemp)
            echo "| REPOSITORY | LOCAL VERSION | LATEST (1) | PREVIOUS (2) | OLDER (3) |" > $tmp_md
            echo "|---|---|---|---|---|" >> $tmp_md

            # Iterate ONLY over the fuzzily selected repositories
            for slug in $selected_slugs
                if test -z "$slug"
                    continue
                end
                
                # Query JSON for the local version of the specific slug
                set -l local_ver (jq -r --arg s "$slug" '.[] | select(.slug == $s) | .local_version' $db_file)
                
                # Fetch releases
                set -l versions_arr (gum spin --spinner dot --title "Fetching versions for $slug..." -- gh api "repos/$slug/releases?per_page=3" --jq '.[].tag_name' 2>/dev/null)
                
                # Fallback to tags
                if test -z "$versions_arr"
                    set versions_arr (gh api "repos/$slug/tags?per_page=3" --jq '.[].name' 2>/dev/null)
                end

                # Setup markdown defaults for empty columns
                set -l rel1 "*N/A*"
                set -l rel2 "*N/A*"
                set -l rel3 "*N/A*"

                # Fish arrays are 1-indexed
                set -l num_versions (count $versions_arr)
                
                # Ensure we don't accidentally print API JSON errors if GitHub limits us
                if test $num_versions -ge 1; and not string match -q "{*" -- "$versions_arr[1]"
                    set rel1 $versions_arr[1]
                end
                if test $num_versions -ge 2; set rel2 $versions_arr[2]; end
                if test $num_versions -ge 3; set rel3 $versions_arr[3]; end

                # Append as a Markdown table row
                echo "| **$slug** | `$local_ver` | $rel1 | $rel2 | $rel3 |" >> $tmp_md
            end

            # Render beautifully using gum format
            gum format < $tmp_md
            
            rm -f $tmp_md

        case lint check
            gum style --foreground 212 "Running native Fish syntax check on this file..."
            if fish_indent --check ~/.config/fish/functions/repo-tracker.fish >/dev/null 2>&1
                gum style --foreground 82 "✅ Syntax check passed! Code is valid Fish."
            else
                gum style --foreground 196 "❌ Syntax check failed. Please check the file formatting."
            end

        case '*'
            __repo_tracker_banner
            echo "Usage:"
            echo "  repo-tracker add <owner/repo>    - Add repo & prompt for local installation"
            echo "  repo-tracker set-version         - Fuzzy search a repo to update its local version"
            echo "  repo-tracker releases            - Fuzzy search repos to display in a Markdown grid table"
            echo "  repo-tracker lint                - Run Fish native syntax check"
    end
end
