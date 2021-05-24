# compile the benchmark apps from lucid to P4 and report results.

# bring up lucid vm
if vagrant up --provider=virtualbox; 
then 
    # in vm: clone latest artifact branch
    echo "cloning latest branch of sigcomm21_artifact@lucid inside of VM..."
    vagrant ssh -c "git clone --single-branch --branch sigcomm21_artifact https://github.com/princetonUniversity/lucid"
    # in vm: rebuild lucid compiler
    echo "rebuilding lucid compiler inside of VM..."
    vagrant ssh -c "cd lucid; make"
    # in vm: build the apps
    echo "running sigcomm_apps/reproduce.sh inside of VM..."
    vagrant ssh -c "cd lucid/sigcomm_apps; ./reproduce.sh"
else
    echo "error: could not bring up vm. Did you run artifact_setup.sh?"
fi