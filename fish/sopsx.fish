function sopsx --wraps=sops --description "sops wrapper for age with 1password"
    # setting up vars
    set --local fetch_key true
    set --local op_secret_ref "op://main/age-pq/age_pq"

    # skip fetching privkey for encryption
    if contains -- -e $argv; 
	or contains -- --encrypt $argv;
	or contains -- -h $argv;
	or contains -- --help $argv;
	or contains -- -v $argv;
	or contains -- --version $argv
        set fetch_key false
    end

    # if decrypting or editing, fetch privkey
    if test "$fetch_key" = true
        set --local age_key (op read "$op_secret_ref" 2>/dev/null)
        
        if test $status -ne 0; or test -z "$age_key"
            echo "Error: failed to fetch the agekey from 1password." >&2
            return 1
        end
        
        SOPS_AGE_KEY="$age_key" command sops $argv
    else
	# run sops directly
        command sops $argv
    end
end

