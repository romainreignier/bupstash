
# Be extra careful to not mess with a user repository
unset BUPSTASH_REPOSITORY
unset BUPSTASH_REPOSITORY_COMMAND
unset BUPSTASH_KEY
unset BUPSTASH_KEY_COMMAND

export CLI_TEST_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
export SCRATCH="${BATS_TMPDIR%/}/bupstash-test-scratch"
export BUPSTASH_KEY="$SCRATCH/bupstash-test-primary.key"
export PUT_KEY="$SCRATCH/bupstash-test-put.key"
export METADATA_KEY="$SCRATCH/bupstash-test-metadata.key"
export LIST_CONTENTS_KEY="$SCRATCH/bupstash-test-list-contents.key"
export BUPSTASH_SEND_LOG="$SCRATCH/send-log.sqlite3"
export BUPSTASH_QUERY_CACHE="$SCRATCH/query-cache.sqlite3"

# We have two modes for running the tests...
# 
# When BUPSTASH_TEST_REPOSITORY_COMMAND is set, we are running
# against an external repository, otherwise we are running against
# a test repository.

if test -z ${BUPSTASH_TEST_REPOSITORY_COMMAND+x}
then
  export BUPSTASH_REPOSITORY="$SCRATCH/bupstash-test-repo"
else
  unset BUPSTASH_REPOSITORY
  export BUPSTASH_REPOSITORY_COMMAND="$BUPSTASH_TEST_REPOSITORY_COMMAND"
fi

setup () {
  rm -rf "$SCRATCH"
  mkdir "$SCRATCH"
  bupstash new-key -o "$BUPSTASH_KEY"
  bupstash new-sub-key --put -o "$PUT_KEY"
  bupstash new-sub-key --list -o "$METADATA_KEY"
  bupstash new-sub-key --list-contents -o "$LIST_CONTENTS_KEY"
  if test -z "$BUPSTASH_REPOSITORY"
  then
    bupstash rm --query-encrypted --allow-many id="*"
    bupstash gc
    rm -f "$BUPSTASH_QUERY_CACHE"
    rm -f "$BUPSTASH_SEND_LOG"
  else
    bupstash init --repository="$BUPSTASH_REPOSITORY"
  fi
}

teardown () {
  chmod -R 700 "$SCRATCH"
  rm -rf "$SCRATCH"
}

@test "simple put+get primary key" {
  data="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
  echo -n "$data" > "$SCRATCH/foo.txt"
  id="$(bupstash put :: "$SCRATCH/foo.txt")"
  test "$data" = "$(bupstash get id=$id )"
}

@test "simple put+get put key" {
  data="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
  echo -n "$data" > "$SCRATCH/foo.txt"
  id="$(bupstash put -k "$PUT_KEY" :: "$SCRATCH/foo.txt")"
  test "$data" = "$(bupstash get id=$id )"
}

@test "simple put+get no compression" {
  data="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
  echo -n "$data" > "$SCRATCH/foo.txt"
  id="$(bupstash put --compression=none -k "$PUT_KEY" :: "$SCRATCH/foo.txt")"
  test "$data" = "$(bupstash get id=$id )"
}

@test "put name override" {
  mkdir "$SCRATCH/d"
  mkdir "$SCRATCH/d/e"
  mkdir "$SCRATCH/d/f"
  echo foo > "$SCRATCH/d/foo.txt"

  id="$(bupstash put name=x.tar "$SCRATCH/d")"
  id="$(bupstash put name=foo "$SCRATCH/d/foo.txt")"
  id="$(bupstash put name=bar.tar "$SCRATCH/d/e" "$SCRATCH/d/f")"
  bupstash get name=x.tar > /dev/null
  bupstash get name=foo > /dev/null
  bupstash get name=bar.tar > /dev/null
}

@test "random data" {
  for i in $(echo 0 1024 4096 1000000 100000000)
  do
    rm -f "$SCRATCH/rand.dat"
    if test $i -gt 0
    then
      head -c $i /dev/urandom > "$SCRATCH/rand.dat"
    else
      # Workaround since macOS's head doesn't support a byte count of 0
      touch "$SCRATCH/rand.dat"
    fi
    id="$(bupstash put -k "$PUT_KEY" :: "$SCRATCH/rand.dat")"
    bupstash get id=$id > "$SCRATCH/got.dat"
    bupstash gc
    cmp --silent "$SCRATCH/rand.dat" "$SCRATCH/got.dat"
  done
}

@test "highly compressible data" {
  for i in $(echo 1024 4096 1000000 100000000)
  do
    rm -f "$SCRATCH/yes.dat"
    dd if=/dev/zero of="$SCRATCH/yes.dat" bs=$i count=1
    id="$(bupstash put -k "$PUT_KEY" :: "$SCRATCH/yes.dat")"
    bupstash get id=$id > "$SCRATCH/got.dat"
    bupstash gc
    cmp --silent "$SCRATCH/yes.dat" "$SCRATCH/got.dat"
  done
}

@test "key mismatch" {
  data="abc123"
  echo -n "$data" > "$SCRATCH/foo.txt"
  id="$(bupstash put :: "$SCRATCH/foo.txt")"
  bupstash new-key -o "$SCRATCH/wrong.key"
  run bupstash get -k "$SCRATCH/wrong.key" id=$id
  echo "$output" | grep -q "key does not match"
  if test $status = 0
  then
    exit 1
  fi
}

@test "corruption detected" {
  if test -z "$BUPSTASH_REPOSITORY"
  then
    skip
  fi
  data="abc123"
  echo -n "$data" > "$SCRATCH/foo.txt"
  id="$(bupstash put :: "$SCRATCH/foo.txt")"
  echo 'XXXXXXXXXXXXXXXXXXXXX' > "$BUPSTASH_REPOSITORY/data/"*;
  run bupstash get id=$id
  echo "$output"
  echo "$output" | grep -q "corrupt"
  if test $status = 0
  then
    exit 1
  fi
}

_concurrent_send_test_worker () {
  set -e
  for i in $(seq 50)
  do
    id="$(bupstash put -e --no-send-log :: echo $i)"
    test "$i" = "$(bupstash get id=$id)"
  done
}

@test "concurrent send" {
  for i in $(seq 10)
  do
    _concurrent_send_test_worker &
  done
  wait
  count=$(bupstash list | expr $(wc -l))
  echo "count is $count"
  test 500 = $count
}

@test "simple search and listing" {
  for i in $(seq 100) # Enough to trigger more than one sync packet.
  do
    bupstash put -e "i=$i" :: echo $i
  done
  for k in $BUPSTASH_KEY $METADATA_KEY
  do
    test 100 = $(bupstash list -k "$k" | expr $(wc -l))
    test 1 = $(bupstash list -k "$k" i=100 | expr $(wc -l))
    test 0 = $(bupstash list -k "$k" i=101 | expr $(wc -l))
  done
}

@test "rm and gc" {
  test 0 = $(bupstash list | expr $(wc -l))
  test 0 = "$(sqlite3 "$SCRATCH/query-cache.sqlite3" 'select count(*) from ItemOpLog;')"
  id1="$(bupstash put -e :: echo hello1)"
  id2="$(bupstash put -e :: echo hello2)"
  test 2 = $(bupstash list | expr $(wc -l))
  test 2 = "$(sqlite3 "$SCRATCH/query-cache.sqlite3" 'select count(*) from ItemOpLog;')"
  if test -n "$BUPSTASH_REPOSITORY"
  then
    test 2 = "$(ls "$BUPSTASH_REPOSITORY/items" | expr $(wc -l))"
    test 2 = "$(ls "$BUPSTASH_REPOSITORY"/data | expr $(wc -l))"
  fi
  bupstash rm id=$id1
  test 1 = $(bupstash list | expr $(wc -l))
  test 3 = "$(sqlite3 "$SCRATCH/query-cache.sqlite3" 'select count(*) from ItemOpLog;')"
  if test -n "$BUPSTASH_REPOSITORY"
  then
    test 1 = "$(ls "$BUPSTASH_REPOSITORY/items" | grep removed | expr $(wc -l))"
    test 1 = "$(ls "$BUPSTASH_REPOSITORY/items" | grep -v removed | expr $(wc -l))"
    test 2 = "$(ls "$BUPSTASH_REPOSITORY"/data | expr $(wc -l))"
  fi
  bupstash gc
  test 1 = $(bupstash list | expr $(wc -l))
  test 1 = "$(sqlite3 "$SCRATCH/query-cache.sqlite3" 'select count(*) from ItemOpLog;')"
  if test -n "$BUPSTASH_REPOSITORY"
  then
    test 1 = "$(ls "$BUPSTASH_REPOSITORY/items" | expr $(wc -l))"
    test 1 = "$(ls "$BUPSTASH_REPOSITORY"/data | expr $(wc -l))"
  fi
  bupstash rm id=$id2
  bupstash gc
  test 0 = $(bupstash list | expr $(wc -l))
  test 0 = "$(sqlite3 "$SCRATCH/query-cache.sqlite3" 'select count(*) from ItemOpLog;')"
  if test -n "$BUPSTASH_REPOSITORY"
  then
    test 0 = "$(ls "$BUPSTASH_REPOSITORY"/data | expr $(wc -l))"
    test 0 = "$(ls "$BUPSTASH_REPOSITORY"/data | expr $(wc -l))"
  fi
}

@test "rm and recover-removed" {
  test 0 = $(bupstash list | expr $(wc -l))
  test 0 = "$(sqlite3 "$SCRATCH/query-cache.sqlite3" 'select count(*) from ItemOpLog;')"
  id1="$(bupstash put -e :: echo hello1)"
  id2="$(bupstash put -e :: echo hello2)"
  test 2 = "$(bupstash list | expr $(wc -l))"
  test 2 = "$(sqlite3 "$SCRATCH/query-cache.sqlite3" 'select count(*) from ItemOpLog;')"
  if test -n "$BUPSTASH_REPOSITORY"
  then
    test 2 = "$(ls "$BUPSTASH_REPOSITORY/items" | expr $(wc -l))"
    test 2 = "$(ls "$BUPSTASH_REPOSITORY"/data | expr $(wc -l))"
  fi
  bupstash rm id=$id1
  bupstash recover-removed
  test 2 = "$(bupstash list | expr $(wc -l))"
  test 4 = "$(sqlite3 "$SCRATCH/query-cache.sqlite3" 'select count(*) from ItemOpLog;')"
  if test -n "$BUPSTASH_REPOSITORY"
  then
    test 2 = "$(ls "$BUPSTASH_REPOSITORY/items" | grep -v removed  | expr $(wc -l))"
    test 2 = "$(ls "$BUPSTASH_REPOSITORY"/data | expr $(wc -l))"
  fi
  bupstash rm id=$id1
  bupstash gc
  bupstash recover-removed
  test 1 = "$(bupstash list | expr $(wc -l))"
  test 1 = "$(sqlite3 "$SCRATCH/query-cache.sqlite3" 'select count(*) from ItemOpLog;')"
  if test -n "$BUPSTASH_REPOSITORY"
  then
    test 1 = "$(ls "$BUPSTASH_REPOSITORY/items" | grep -v removed | expr $(wc -l))"
    test 1 = "$(ls "$BUPSTASH_REPOSITORY"/data | expr $(wc -l))"
  fi
  bupstash rm id=$id2
  bupstash gc
  bupstash recover-removed
  test 0 = "$(bupstash list | expr $(wc -l))"
  test 0 = "$(sqlite3 "$SCRATCH/query-cache.sqlite3" 'select count(*) from ItemOpLog;')"
  if test -n "$BUPSTASH_REPOSITORY"
  then
    test 0 = "$(ls "$BUPSTASH_REPOSITORY/items" | expr $(wc -l))"
    test 0 = "$(ls "$BUPSTASH_REPOSITORY"/data | expr $(wc -l))"
  fi
}

@test "query sync" {
  id1="$(bupstash put -e :: echo hello1)"
  test 1 = $(bupstash list | expr $(wc -l))
  id2="$(bupstash put -e :: echo hello2)"
  test 2 = $(bupstash list | expr $(wc -l))
  bupstash rm id=$id1
  test 1 = $(bupstash list | expr $(wc -l))
  bupstash gc
  test 1 = $(bupstash list | expr $(wc -l))
  bupstash rm id=$id2
  test 0 = $(bupstash list | expr $(wc -l))
  bupstash gc
  test 0 = $(bupstash list | expr $(wc -l))
}

@test "get via query" {
  bupstash put -e foo=bar  echo -n hello1 
  bupstash put -e foo=baz  echo -n hello2 
  bupstash put -e foo=bang echo -n hello2 
  test "hello2" = $(bupstash get "foo=ban*")
}

@test "rm via query" {
  bupstash put -e  foo=bar  echo -n hello1 
  bupstash put -e  foo=baz  echo -n hello2
  bupstash put -e  foo=bang echo -n hello2
  test 3 = $(bupstash list | expr $(wc -l))
  if bupstash rm "foo=*"
  then
    exit 1
  fi
  bupstash rm "foo=bar"
  test 2 = $(bupstash list | expr $(wc -l))
  bupstash rm --allow-many -k "$METADATA_KEY" "foo=*"
  test 0 = $(bupstash list | expr $(wc -l))
}

@test "send directory sanity" {
  mkdir "$SCRATCH/foo"
  echo a > "$SCRATCH/foo/a.txt"
  echo b > "$SCRATCH/foo/b.txt"
  mkdir "$SCRATCH/foo/bar"
  echo c > "$SCRATCH/foo/bar/c.txt"
  id=$(bupstash put :: "$SCRATCH/foo")
  test 5 = "$(bupstash get id=$id | tar -tf - | expr $(wc -l))"
  # Test again to excercise stat caching.
  id=$(bupstash put :: "$SCRATCH/foo")
  test 5 = "$(bupstash get id=$id | tar -tf - | expr $(wc -l))"
  id=$(bupstash put :: "$SCRATCH/foo/a.txt" "$SCRATCH/foo/b.txt")
  test 3 = "$(bupstash get id=$id | tar -tf - | expr $(wc -l))"
}

@test "send directory no stat cache" {
  mkdir "$SCRATCH/foo"
  echo a > "$SCRATCH/foo/a.txt"
  echo b > "$SCRATCH/foo/b.txt"
  mkdir "$SCRATCH/foo/bar"
  echo c > "$SCRATCH/foo/bar/c.txt"
  id=$(bupstash put --no-send-log :: "$SCRATCH/foo")
  test 5 = "$(bupstash get id=$id | tar -tf - | expr $(wc -l))"
  id=$(bupstash put --no-stat-caching :: "$SCRATCH/foo")
  test 5 = "$(bupstash get id=$id | tar -tf - | expr $(wc -l))"
}

@test "stat cache invalidated" {
  mkdir "$SCRATCH/foo"
  echo a > "$SCRATCH/foo/a.txt"
  id=$(bupstash put :: "$SCRATCH/foo")
  bupstash rm id=$id
  bupstash gc
  id=$(bupstash put :: "$SCRATCH/foo")
  bupstash get id=$id > /dev/null
}

@test "repository command" {
  if test -z "$BUPSTASH_REPOSITORY"
  then
    skip
  fi
  export BUPSTASH_REPOSITORY_COMMAND="bupstash serve $BUPSTASH_REPOSITORY"
  unset BUPSTASH_REPOSITORY
  data="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
  echo -n "$data" > "$SCRATCH/foo.txt"
  id="$(bupstash put :: "$SCRATCH/foo.txt")"
  test "$data" = "$(bupstash get id=$id )"
}

@test "key command" {
  export BUPSTASH_KEY_COMMAND="cat $BUPSTASH_KEY"
  data="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
  echo -n "$data" > "$SCRATCH/foo.txt"
  id="$(bupstash put :: "$SCRATCH/foo.txt")"
  test "$data" = "$(bupstash get id=$id )"
}

@test "long path" {
  mkdir "$SCRATCH/foo"
  mkdir -p "$SCRATCH/foo/"aaaaaaaaaaaaaaaaaaa/aaaaaaaaaaaaaaaaaaaaaaa\
aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/aaaaaaaaaaaaaaaaaaaaaaa\
aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/aaaaaaaaaaaaaaaaaaaaaaa\
aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/aaaaaaaaaaaaaaaaaaaaaaa\
aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/aaaaaaaaaaaaaaaaaaaaaaa
  id=$(bupstash put :: "$SCRATCH/foo")
  test 7 = "$(bupstash get id=$id | tar -tf - | expr $(wc -l))"
}

@test "long link target" {
  mkdir "$SCRATCH/foo"
  ln -s llllllllllllllllllllllllllllllllllllllllllllllllllllllllllll\
llllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllll\
llllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllll\
llllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllll\
llllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllll\
    "$SCRATCH/foo/l"
  id=$(bupstash put :: "$SCRATCH/foo")
  test 2 = "$(bupstash get id=$id | tar -tf - | expr $(wc -l))"
}

@test "put and list non-utf8 paths" {
  if test $(uname) = "Darwin"
  then
    skip "Darwin utilities cannot handle test paths"
  fi
  mkdir "$SCRATCH/d"
  ln -s $(echo -ne "\xe2\x28\xa1") $(echo -ne "$SCRATCH/d/\xe2\x28\xa1")
  id="$(bupstash put "$SCRATCH/d")"
  bupstash list-contents --format=jsonl1 id="$id"
  p=$(bupstash list-contents --format=jsonl1 id="$id" | tail -n 1 | jq -c .path)
  l=$(bupstash list-contents --format=jsonl1 id="$id" | tail -n 1 | jq -c .link_target)
  test "$p" = "[226,40,161]"
  test "$l" = "[226,40,161]"
}

@test "exclusions" {
  mkdir "$SCRATCH/foo"
  touch "$SCRATCH/foo/bang"
  mkdir "$SCRATCH/foo/bar"
  touch "$SCRATCH/foo/bar/bang"
  mkdir "$SCRATCH/foo/bar/baz"
  touch "$SCRATCH/foo/bar/baz/bang"

  # No exclude, everything should be in
  id=$(bupstash put :: "$SCRATCH/foo")
  test 6 = "$(bupstash get id=$id | tar -tf - | expr $(wc -l))"

  # Exclude on multiple levels
  # As expected, this also excludes $SCRATCH/foo/bang
  id=$(bupstash put --exclude="$SCRATCH/foo/**/bang" :: "$SCRATCH/foo")
  bupstash get id=$id | tar -tf -
  test 3 = "$(bupstash get id=$id | tar -tf - | expr $(wc -l))"

  # Exclude on multiple levels (should be the same)
  id=$(bupstash put --exclude="**/bang" :: "$SCRATCH/foo")
  test 3 = "$(bupstash get id=$id | tar -tf - | expr $(wc -l))"

  # Exclude on multiple levels (should still be the same)
  id=$(bupstash put --exclude="/**/bang" :: "$SCRATCH/foo")
  test 3 = "$(bupstash get id=$id | tar -tf - | expr $(wc -l))"

  # Still the same thing, but using the "match on name" shorthand (no slashes = only file name)
  id=$(bupstash put --exclude="bang" :: "$SCRATCH/foo")
  test 3 = "$(bupstash get id=$id | tar -tf - | expr $(wc -l))"

  # Exclude on a single level
  # We want /foo /foo/bar /foo/bar/baz /foo/bang /foo/bar/baz/bang (that one's important)
  id=$(bupstash put --exclude="$SCRATCH/foo/*/bang" :: "$SCRATCH/foo")
  test 5 = "$(bupstash get id=$id | tar -tf - | expr $(wc -l))"

  # Exclude on a single level, but wrongly so (nothing gets excluded)
  id=$(bupstash put --exclude="/*/bang" :: "$SCRATCH/foo")
  test 6 = "$(bupstash get id=$id | tar -tf - | expr $(wc -l))"

  # Invalid exclusion regex
  ! bupstash put --exclude="*/bar" :: "$SCRATCH/foo"
}

# Test exclude marker files
@test "exclude if exists" {
  mkdir "$SCRATCH/foo"
  touch "$SCRATCH/foo/bang"
  mkdir "$SCRATCH/foo/bar"
  touch "$SCRATCH/foo/bar/bang"
  touch "$SCRATCH/foo/bar/.backupignore"
  mkdir "$SCRATCH/foo/bar/baz"
  touch "$SCRATCH/foo/bar/baz/bang"

  # Keep . bang bar
  id=$(bupstash put --exclude-if-present=".backupignore" :: "$SCRATCH/foo")
  test 4 = "$(bupstash get id=$id | tar -tf - | expr $(wc -l))"
}

@test "checkpoint plain data" {
  # Excercise the checkpointing code, does not check
  # cache invalidation, that is covered via unit tests.
  
  # Big enough for multiple chunks
  n=100000000
  export BUPSTASH_CHECKPOINT_SECONDS=0 # Checkpoint as often as possible
  head -c $n /dev/urandom > "$SCRATCH/rand.dat"
  id="$(bupstash put :: "$SCRATCH/rand.dat")"
  bupstash get id=$id > "$SCRATCH/got.dat"
  bupstash gc
  cmp --silent "$SCRATCH/rand.dat" "$SCRATCH/got.dat"
}

@test "checkpoint directories" {
  # Excercise the checkpointing code, does not check
  # cache invalidation, that is covered via unit tests.

  mkdir "$SCRATCH/foo"
  # There currently is at least one chunk per directory, create many
  # to ensure there are enough chunks to trigger a few checkpoints.
  for i in `seq 50`
  do
    mkdir "$SCRATCH/foo/bar$i"
    echo foo > "$SCRATCH/foo/bar$i/data"
  done
  export BUPSTASH_CHECKPOINT_SECONDS=0 # Checkpoint as often as possible
  id=$(bupstash put :: "$SCRATCH/foo")
  test 101 = "$(bupstash get id=$id | tar -tf - | expr $(wc -l))"
}

@test "rm from stdin" {
  id1="$(bupstash put -e echo hello1)"
  id2="$(bupstash put -e echo hello2)"
  id3="$(bupstash put -e echo hello3)"
  test 3 = "$(bupstash list | expr $(wc -l))"
  echo "${id1}" | bupstash rm --ids-from-stdin
  test 2 = "$(bupstash list | expr $(wc -l))"
  echo -e "${id2}\n${id3}" | bupstash rm --ids-from-stdin
  test 0 = "$(bupstash list | expr $(wc -l))"
}

_concurrent_modify_worker () {
  set -e
  while test $(date "+%s") -lt "$1"
  do
    touch $SCRATCH/t/a$2
    touch $SCRATCH/t/b$2
    touch $SCRATCH/t/c$2
    mkdir $SCRATCH/t/d$2
    touch $SCRATCH/t/d$2/e$2
    ln -s a $SCRATCH/t/f$2

    echo a >> $SCRATCH/t/a$2
    echo b >> $SCRATCH/t/b$2
    echo c >> $SCRATCH/t/c$2
    echo e >> $SCRATCH/t/d$2/e$2

    echo "" > $SCRATCH/t/a$2
    echo "" > $SCRATCH/t/b$2
    echo "" > $SCRATCH/t/c$2
    echo "" > $SCRATCH/t/d$2/e$2

    rm $SCRATCH/t/a$2
    rm $SCRATCH/t/b$2
    rm $SCRATCH/t/c$2
    rm -rf $SCRATCH/t/d$2
    rm $SCRATCH/t/f$2
  done
}

@test "concurrent dir modify during put" {
  now=$(date "+%s")
  test_end=$(($now + 5))
  mkdir $SCRATCH/t
  for i in $(seq 10)
  do
    _concurrent_modify_worker $test_end $i &
  done

  while test $(date "+%s") -lt "$test_end"
  do
    bupstash put "$SCRATCH/t"
  done

  wait

  for id in $(bupstash list --format=jsonl1 | jq -r .id)
  do
    bupstash get id=$id | tar -tf - > /dev/null
  done
}

@test "list and rm no key" {
  bupstash put -e echo hello1
  bupstash put -e echo hello2
  unset BUPSTASH_KEY
  test 2 = "$(bupstash list --query-encrypted | expr $(wc -l))"
  bupstash rm --allow-many --query-encrypted id='*'
  test 0 = "$(bupstash list --query-encrypted | expr $(wc -l))"
}

@test "pick and index" {
  
  mkdir $SCRATCH/foo
  mkdir $SCRATCH/foo/baz
  
  for n in `seq 5`
  do
    # Create some test files scattered in two directories.
    # Small files
    head -c $((10 + $(head -c 4 /dev/urandom | cksum | cut -f1 -d " " | head -c 3))) /dev/urandom > "$SCRATCH/foo/$(uuidgen)"
    head -c $((10 + $(head -c 4 /dev/urandom | cksum | cut -f1 -d " " | head -c 3))) /dev/urandom > "$SCRATCH/foo/baz/$(uuidgen)"
    # Large files
    head -c $((10000 + $(head -c 4 /dev/urandom | cksum | cut -f1 -d " " | head -c 7))) /dev/urandom > "$SCRATCH/foo/$(uuidgen)"
    head -c $((10000 + $(head -c 4 /dev/urandom | cksum | cut -f1 -d " " | head -c 7))) /dev/urandom > "$SCRATCH/foo/baz/$(uuidgen)"
  done

  # Loop so we test cache code paths
  for i in `seq 2`
  do
    id="$(bupstash put $SCRATCH/foo)"
    for f in $(sh -c "cd $SCRATCH/foo && find . -type f | cut -c 3-")
    do
      cmp <(bupstash get --pick "$f" id=$id) "$SCRATCH/foo/$f"
    done
    test $(bupstash get id=$id | tar -tf - | expr $(wc -l)) = 22
    bupstash get --pick . id=$id | tar -tf -
    test $(bupstash get --pick . id=$id | tar -tf - | expr $(wc -l)) = 22
    test $(bupstash get --pick baz id=$id | tar -tf - | expr $(wc -l)) = 11
    test $(bupstash list-contents  id=$id | expr $(wc -l)) = 22
  done
}

@test "multi dir put" {
  mkdir "$SCRATCH/foo"
  mkdir "$SCRATCH/foo/bar"
  mkdir "$SCRATCH/foo/bar/baz"
  mkdir "$SCRATCH/foo/bang"
  echo foo > "$SCRATCH/foo/bar/baz/a.txt"

  id=$(bupstash put :: "$SCRATCH/foo/bar" "$SCRATCH/foo/bar/baz" "$SCRATCH/foo/bang")
  bupstash get id=$id | tar -tf -
  test 5 = "$(bupstash get id=$id | tar -tf - | expr $(wc -l))"
  test 5 = "$(bupstash list-contents id=$id | expr $(wc -l))"
  test 5 = "$(bupstash list-contents -k $LIST_CONTENTS_KEY id=$id | expr $(wc -l))"
}

@test "list-contents pick" {
  mkdir "$SCRATCH/foo"
  mkdir "$SCRATCH/foo/bar"
  mkdir "$SCRATCH/foo/bar/baz"
  mkdir "$SCRATCH/foo/bang"
  echo foo > "$SCRATCH/foo/bar/baz/a.txt"

  id=$(bupstash put :: "$SCRATCH/foo")
  test 5 = "$(bupstash list-contents id=$id | expr $(wc -l))"
  test 5 = "$(bupstash list-contents --pick . id=$id | expr $(wc -l))"
  test 3 = "$(bupstash list-contents --pick bar id=$id | expr $(wc -l))"
}

@test "hard link short path" {
  mkdir "$SCRATCH/foo"
  touch "$SCRATCH/foo/a"
  ln "$SCRATCH/foo/a" "$SCRATCH/foo/b"

  id=$(bupstash put :: "$SCRATCH/foo")
  mkdir "$SCRATCH/restore"
  bupstash get id=$id | tar -C "$SCRATCH/restore" -xvf -

  echo -n 'x' >> "$SCRATCH/restore/a"
  test "x" = $(cat "$SCRATCH/restore/b")
}

@test "long hard link target" {
  a="aaaaaaaaaa"
  name="$a$a$a$a$a$a$a$a$a$a$a$a$a$a$a$a$a$a$a$a"
  mkdir "$SCRATCH/foo"
  touch "$SCRATCH/foo/$name"
  ln "$SCRATCH/foo/$name" "$SCRATCH/foo/b"

  id=$(bupstash put :: "$SCRATCH/foo")
  mkdir "$SCRATCH/restore"

  if test $(uname) != "Linux"
  then
    bupstash get id=$id | gtar -C "$SCRATCH/restore" -xvf -
  else
    bupstash get id=$id | tar -C "$SCRATCH/restore" -xvf -
  fi

  echo -n 'x' >> "$SCRATCH/restore/$name"
  test "x" = "$(cat "$SCRATCH/restore/b")"
}

@test "hard link to symlink" {
  if test $(uname) != "Linux"
  then
    skip "Test disabled on non-linux operating systems"
  fi

  mkdir "$SCRATCH/foo"
  touch "$SCRATCH/foo/a"
  ln -s "$SCRATCH/foo/a" "$SCRATCH/foo/b"
  ln -n "$SCRATCH/foo/b" "$SCRATCH/foo/c"

  id=$(bupstash put :: "$SCRATCH/foo")
  mkdir "$SCRATCH/restore"
  bupstash get id=$id | tar -C "$SCRATCH/restore" -xvf -

  readlink "$SCRATCH/restore/c"
}

@test "simple diff" {
  mkdir "$SCRATCH/d"
  echo -n "abc" > "$SCRATCH/d/a.txt"
  id1="$(bupstash put --no-send-log "$SCRATCH/d")"
  echo -n "def" > "$SCRATCH/d/b.txt"
  id2="$(bupstash put --no-send-log "$SCRATCH/d")"
  echo -n "hij" >> "$SCRATCH/d/b.txt"
  id3="$(bupstash put --no-send-log "$SCRATCH/d")"
  test 3 = "$(bupstash diff id=$id1 :: id=$id2 | expr $(wc -l))"
  test 2 = "$(bupstash diff id=$id1 :: id=$id2 | grep "^\\+" | expr $(wc -l))"
  test 2 = "$(bupstash diff id=$id2 :: id=$id3 | expr $(wc -l))"
  test 1 = "$(bupstash diff id=$id2 :: id=$id3 | grep "^\\+" | expr $(wc -l))"
}

@test "diff ignore" {
  mkdir "$SCRATCH/d"
  echo -n "abc" > "$SCRATCH/d/a.txt"
  id1="$(bupstash put --no-send-log "$SCRATCH/d")"
  echo -n "abc" > "$SCRATCH/d/a.txt"
  id2="$(bupstash put --no-send-log "$SCRATCH/d")"
  echo -n "def" > "$SCRATCH/d/a.txt"
  id3="$(bupstash put --no-send-log "$SCRATCH/d")"
  test 0 = "$(bupstash diff --ignore times id=$id1 :: id=$id2 | expr $(wc -l))"
  test 2 = "$(bupstash diff --ignore times id=$id2 :: id=$id3 | expr $(wc -l))"
  test 0 = "$(bupstash diff --ignore times,content id=$id2 :: id=$id3 | expr $(wc -l))"
}

@test "simple local diff" {
  mkdir "$SCRATCH"/d{1,2,3}
  echo -n "abc" > "$SCRATCH/d1/a.txt"
  echo -n "abc" > "$SCRATCH/d2/a.txt"
  echo -n "abcd" > "$SCRATCH/d3/a.txt"
  test 4 = "$(bupstash diff $SCRATCH/d1 :: $SCRATCH/d2 | expr $(wc -l))"
  test 0 = "$(bupstash diff --relaxed $SCRATCH/d1 :: $SCRATCH/d2 | expr $(wc -l))"
  test 2 = "$(bupstash diff --relaxed $SCRATCH/d1 :: $SCRATCH/d3 | expr $(wc -l))"
}

@test "access controls" {
  if ! test -d "$BUPSTASH_REPOSITORY" || test -n "$BUPSTASH_REPOSITORY_COMMAND"
  then
    skip "test requires a local repository"
  fi

  mkdir "$SCRATCH/d"
  id="$(bupstash put "$SCRATCH/d")"

  REPO="$BUPSTASH_REPOSITORY"
  unset BUPSTASH_REPOSITORY

  export BUPSTASH_REPOSITORY_COMMAND="bupstash serve --allow-get $REPO"
  bupstash get id=$id > /dev/null
  bupstash list
  bupstash list-contents id=$id
  if bupstash init ; then exit 1 ; fi
  if bupstash put -e echo hi ; then exit 1 ; fi
  if bupstash rm id=$id ; then exit 1 ; fi
  if bupstash recover-removed ; then exit 1 ; fi
  if bupstash gc ; then exit 1 ; fi
  if bupstash gc ; then exit 1 ; fi

  export BUPSTASH_REPOSITORY_COMMAND="bupstash serve --allow-put $REPO"
  bupstash put -e echo hi
  if bupstash init ; then exit 1 ; fi
  if bupstash get id=$id > /dev/null ; then exit 1 ; fi
  if bupstash list  ; then exit 1 ; fi
  if bupstash list-contents id=$id  ; then exit 1 ; fi
  if bupstash rm id=$id ; then exit 1 ; fi
  if bupstash recover-removed ; then exit 1 ; fi
  if bupstash gc ; then exit 1 ; fi

  export BUPSTASH_REPOSITORY_COMMAND="bupstash serve --allow-list $REPO"
  bupstash list
  bupstash list-contents id=$id
  if bupstash init ; then exit 1 ; fi
  if bupstash get id=$id > /dev/null ; then exit 1 ; fi
  if bupstash put -e echo hi ; then exit 1 ; fi
  if bupstash rm id=$id ; then exit 1 ; fi
  if bupstash recover-removed ; then exit 1 ; fi
  if bupstash gc ; then exit 1 ; fi

  export BUPSTASH_REPOSITORY_COMMAND="bupstash serve --allow-gc $REPO"
  if bupstash init ; then exit 1 ; fi
  if bupstash put -e echo hi ; then exit 1 ; fi
  if bupstash get id=$id > /dev/null ; then exit 1 ; fi
  if bupstash list  ; then exit 1 ; fi
  if bupstash list-contents id=$id  ; then exit 1 ; fi
  if bupstash rm id=$id ; then exit 1 ; fi
  if bupstash recover-removed ; then exit 1 ; fi
  bupstash gc

  export BUPSTASH_REPOSITORY_COMMAND="bupstash serve --allow-remove $REPO"
  bupstash list
  bupstash list-contents id=$id
  if bupstash init ; then exit 1 ; fi
  if bupstash get id=$id > /dev/null ; then exit 1 ; fi
  if bupstash put -e echo hi ; then exit 1 ; fi
  if bupstash recover-removed ; then exit 1 ; fi
  if bupstash gc ; then exit 1 ; fi
  # delete as the last test
  bupstash rm id=$id

  export BUPSTASH_REPOSITORY_COMMAND="bupstash serve --allow-get --allow-put $REPO"
  bupstash recover-removed

  export BUPSTASH_REPOSITORY_COMMAND="bupstash serve $REPO"
  export BUPSTASH_TO_REPOSITORY_COMMAND="bupstash serve --allow-get --allow-put --allow-list --allow-gc --allow-remove $REPO"
  if bupstash sync ; then exit 1 ; fi
  export BUPSTASH_TO_REPOSITORY_COMMAND="bupstash serve --allow-sync $REPO"
  bupstash sync
}

@test "restore sanity" {
  mkdir "$SCRATCH"/{d,restore}
  echo -n "abc" > "$SCRATCH/d/a.txt"
  id=$(bupstash put $SCRATCH/d)
  bupstash restore --into $SCRATCH/restore id=$id
  test 0 = "$(bupstash diff --relaxed $SCRATCH/d :: $SCRATCH/restore | expr $(wc -l))"
}

@test "restore symlink" {
  mkdir "$SCRATCH"/{d,restore}
  ln -s missing.txt "$SCRATCH"/d/l
  id=$(bupstash put "$SCRATCH"/d)
  bupstash restore --into "$SCRATCH"/restore id=$id
  test 0 = "$(bupstash diff --relaxed "$SCRATCH"/d :: "$SCRATCH"/restore | expr $(wc -l))"
}

@test "restore hardlink" {
  mkdir "$SCRATCH"/{d,restore}
  echo -n "abc" > "$SCRATCH/d/a.txt"
  ln "$SCRATCH"/d/a.txt "$SCRATCH"/d/b.txt
  id=$(bupstash put "$SCRATCH"/d)
  bupstash restore --into "$SCRATCH"/restore id=$id
  test 0 = "$(bupstash diff --relaxed "$SCRATCH"/d :: "$SCRATCH"/restore | expr $(wc -l))"
  echo -n "xxx" >> "$SCRATCH/restore/a.txt"
  test $(cat "$SCRATCH"/restore/a.txt) = $(cat "$SCRATCH"/restore/b.txt)
}

@test "restore hardlink prexisting" {
  mkdir "$SCRATCH"/{d,restore}
  echo -n "abc" > "$SCRATCH/d/a.txt"
  ln "$SCRATCH"/d/a.txt "$SCRATCH"/d/b.txt

  # Test b becomes a hard link.
  echo -n "abc" > "$SCRATCH/restore/a.txt"
  echo -n "abc" > "$SCRATCH/restore/b.txt"
  
  id=$(bupstash put "$SCRATCH"/d)
  bupstash restore --into "$SCRATCH"/restore id=$id
  test 0 = "$(bupstash diff --relaxed "$SCRATCH"/d :: "$SCRATCH"/restore | expr $(wc -l))"
  echo -n "xxx" >> "$SCRATCH/restore/a.txt"
  test $(cat "$SCRATCH"/restore/a.txt) = $(cat "$SCRATCH"/restore/b.txt)
}

@test "restore read only" {
  mkdir "$SCRATCH"/{d,restore}

  mkdir "$SCRATCH"/d/b
  echo -n "abc" > "$SCRATCH"/d/b/a.txt
  chmod -w "$SCRATCH"{/d/b,/d/b/a.txt}

  mkdir "$SCRATCH"/restore/{b,c}
  echo -n "xxx" > "$SCRATCH"/restore/c/x.txt
  echo -n "yyy" > "$SCRATCH"/restore/b/a.txt
  chmod -w "$SCRATCH"/restore/b/a.txt
  chmod -R -w "$SCRATCH"/restore/c

  id=$(bupstash put "$SCRATCH"/d)
  bupstash restore --into $SCRATCH/restore id=$id
  test 0 = "$(bupstash diff --relaxed $SCRATCH/d :: $SCRATCH/restore | expr $(wc -l))"
}

@test "restore pick" {
  mkdir "$SCRATCH"/{d,d/a,d/b,d/c,restore}
  echo -n "abc" > "$SCRATCH/d/a/a.txt"
  echo -n "def" > "$SCRATCH/d/b/b.txt"
  echo -n "hij" > "$SCRATCH/d/c/c.txt"
  id=$(bupstash put "$SCRATCH"/d)
  bupstash restore --pick b --into $SCRATCH/restore id=$id
  test 0 = "$(bupstash diff --relaxed $SCRATCH/d/b :: $SCRATCH/restore | expr $(wc -l))"
}

@test "restore sparse" {
  sparse_dir="$SCRATCH/random_dir"
  restore_dir="$SCRATCH/restore_dir"
  mkdir "$sparse_dir" "$restore_dir"

  # create sparse files with holes in different places.
  truncate -s 16M "$sparse_dir/file.img"
  
  echo data > "$sparse_dir/file_with_data1.img"
  truncate -s 16M $sparse_dir/file_with_data1.img
  
  echo data > $sparse_dir/file_with_data2.img
  truncate -s 16M $sparse_dir/file_with_data2.img
  echo data >> $sparse_dir/file_with_data2.img

  id=$(bupstash put :: "$sparse_dir")
  bupstash restore --into "$restore_dir" "id=$id"

  diff -u \
    <(cd "$sparse_dir" ; find . | sort) \
    <(cd "$restore_dir" ; find . | sort)

  for f in $(cd "$sparse_dir" ; find . -type f | cut -c 3-)
  do
    cmp "$sparse_dir/$f" "$restore_dir/$f"
    test "$(du "$sparse_dir/$f"  | awk '{print $1}' )" -ge \
         "$(du "$restore_dir/$f" | awk '{print $1}' )"
  done
}

@test "incremental restore fuzz torture" {
  
  rand_dir="$SCRATCH/random_dir"
  restore_dir="$SCRATCH/restore_dir"

  mkdir "$restore_dir"

  for i in $(seq 50)
  do
    rm -rf "$rand_dir"
    "$BATS_TEST_DIRNAME/mk-random-dir.py" "$rand_dir"

    # Put twice so we test caching code paths.
    id1=$(bupstash put :: "$rand_dir")
    id2=$(bupstash put :: "$rand_dir")

    for id in $(echo $id1 $id2)
    do
      bupstash restore --into "$restore_dir" "id=$id"
      test 0 = "$(bupstash diff --relaxed "$rand_dir" :: "$restore_dir" | expr $(wc -l))"

      for i in $(seq 3)
      do
        for to_delete in $(find "$restore_dir" -type f | shuf -n "$i")
        do
          rm "$to_delete"
        done
        bupstash restore --into "$restore_dir" "id=$id"
        test 0 = "$(bupstash diff --relaxed "$rand_dir" :: "$restore_dir" | expr $(wc -l))"
      done

      bupstash rm id=$id
    done

    bupstash gc
  done
}

@test "restore pick torture" {
  
  if test -z "$BUPSTASH_TORTURE_DIR"
  then
    skip "Set BUPSTASH_TORTURE_DIR to run this test."
  fi

  restore_dir="$SCRATCH/restore_dir"
  copy_dir="$SCRATCH/copy_dir"
  # Put twice so we test caching code paths.
  id1=$(bupstash put :: "$BUPSTASH_TORTURE_DIR")
  id2=$(bupstash put :: "$BUPSTASH_TORTURE_DIR")

  for id in $(echo $id1 $id2)
  do
    for d in $(cd "$BUPSTASH_TORTURE_DIR" ; find . -type d | sed 's,^\./,,g')
    do
      rm -rf "$copy_dir" "$restore_dir"
      mkdir "$copy_dir" "$restore_dir"

      tar -C "$BUPSTASH_TORTURE_DIR/$d" -cf - . | tar -C "$copy_dir" -xf -
      bupstash restore --into "$restore_dir" --pick "$d" "id=$id"

      diff -u \
        <(cd "$restore_dir" ; find . | sort) \
        <(cd "$copy_dir" ; find . | sort)

      for f in $(cd "$copy_dir" ; find . -type f | cut -c 3-)
      do
        cmp "$copy_dir/$f" "$restore_dir/$f"
      done
    done
  done
}

@test "restore pick fuzz torture" {
  
  rand_dir="$SCRATCH/random_dir"
  restore_dir="$SCRATCH/restore_dir"
  copy_dir="$SCRATCH/copy_dir"

  for i in `seq 50`
  do
    rm -rf "$rand_dir"

    "$BATS_TEST_DIRNAME/mk-random-dir.py" "$rand_dir"

    # Put twice so we test caching code paths.
    id1=$(bupstash put :: "$rand_dir")
    id2=$(bupstash put :: "$rand_dir")

    for id in $(echo $id1 $id2)
    do
      for d in $(cd "$rand_dir" ; find . -type d | sed 's,^\./,,g')
      do
        rm -rf "$copy_dir" "$restore_dir"
        mkdir "$copy_dir" "$restore_dir"

        tar -C "$rand_dir/$d" -cf - . | tar -C "$copy_dir" -xf -
        bupstash restore --into "$restore_dir" --pick "$d" "id=$id"

        diff -u \
          <(cd "$restore_dir" ; find . | sort) \
          <(cd "$copy_dir" ; find . | sort)

        for f in $(cd "$copy_dir" ; find . -type f | cut -c 3-)
        do
          cmp "$copy_dir/$f" "$restore_dir/$f"
        done
      done
      bupstash rm id=$id
    done

    bupstash gc
  done
}

@test "get pick torture" {
  
  if test -z "$BUPSTASH_TORTURE_DIR"
  then
    skip "Set BUPSTASH_TORTURE_DIR to run this test."
  fi

  restore_dir="$SCRATCH/restore_dir"
  copy_dir="$SCRATCH/copy_dir"
  # Put twice so we test caching code paths.
  id1=$(bupstash put :: "$BUPSTASH_TORTURE_DIR")
  id2=$(bupstash put :: "$BUPSTASH_TORTURE_DIR")

  for id in $(echo $id1 $id2)
  do
    for f in $(cd "$BUPSTASH_TORTURE_DIR" ; find . -type f | cut -c 3-)
    do
      cmp <(bupstash get --pick "$f"  "id=$id") "$BUPSTASH_TORTURE_DIR/$f"
    done

    for d in $(cd "$BUPSTASH_TORTURE_DIR" ; find . -type d | sed 's,^\./,,g')
    do
      rm -rf "$copy_dir" "$restore_dir"
      mkdir "$copy_dir" "$restore_dir"

      tar -C "$BUPSTASH_TORTURE_DIR/$d" -cf - . | tar -C "$copy_dir" -xf -
      bupstash get --pick "$d" "id=$id" | tar -C "$restore_dir" -xf -

      diff -u \
        <(cd "$restore_dir" ; find . | sort) \
        <(cd "$copy_dir" ; find . | sort)

      for f in $(cd "$copy_dir" ; find . -type f | cut -c 3-)
      do
        cmp "$copy_dir/$f" "$restore_dir/$f"
      done
    done
  done
}

@test "get pick fuzz torture" {
  
  rand_dir="$SCRATCH/random_dir"
  restore_dir="$SCRATCH/restore_dir"
  copy_dir="$SCRATCH/copy_dir"

  for i in `seq 50`
  do
    rm -rf "$rand_dir"

    "$BATS_TEST_DIRNAME/mk-random-dir.py" "$rand_dir"

    # Put twice so we test caching code paths.
    id1=$(bupstash put :: "$rand_dir")
    id2=$(bupstash put :: "$rand_dir")

    for id in $(echo $id1 $id2)
    do
      for f in $(cd "$rand_dir" ; find . -type f | cut -c 3-)
      do
        cmp <(bupstash get --pick "$f"  "id=$id") "$rand_dir/$f"
      done

      for d in $(cd "$rand_dir" ; find . -type d | sed 's,^\./,,g')
      do
        rm -rf "$copy_dir" "$restore_dir"
        mkdir "$copy_dir" "$restore_dir"

        tar -C "$rand_dir/$d" -cf - . | tar -C "$copy_dir" -xf -
        bupstash get --pick "$d" "id=$id" | tar -C "$restore_dir" -xf -

        diff -u \
          <(cd "$restore_dir" ; find . | sort) \
          <(cd "$copy_dir" ; find . | sort)

        for f in $(cd "$copy_dir" ; find . -type f | cut -c 3-)
        do
          cmp "$copy_dir/$f" "$restore_dir/$f"
        done
      done
    
      bupstash rm id=$id
    done

    bupstash gc
  done
}

@test "repo rollback torture" {
  if ! test -d "$BUPSTASH_REPOSITORY" || \
       test -n "$BUPSTASH_REPOSITORY_COMMAND"
  then
    skip "test requires a local repository"
  fi

  REPO="$BUPSTASH_REPOSITORY"
  unset BUPSTASH_REPOSITORY

  now=$(date "+%s")
  test_end=$(($now + 15))

  while test $(date "+%s") -lt "$test_end"
  do
    # XXX This timeout scheme is very brittle.
    export BUPSTASH_REPOSITORY_COMMAND="timeout -s KILL 0.0$(($RANDOM % 10)) bupstash serve $REPO"
    bupstash put -e echo $(uuidgen) || true
    bupstash gc > /dev/null || true
    bupstash rm --allow-many "id=f*" || true
    if test "$(($RANDOM % 2))" = 0
    then
      bupstash recover-removed || true
    fi
  done

  unset BUPSTASH_REPOSITORY_COMMAND
  export BUPSTASH_REPOSITORY="$REPO"

  bupstash gc > /dev/null
  bupstash list --query-cache="$SCRATCH/sanity.qcache" > /dev/null
}

@test "repo sync" {
  bupstash init -r "$SCRATCH/sync1"
  bupstash init -r "$SCRATCH/sync2"
  id1="$(echo foo | bupstash put -k "$PUT_KEY" -)"
  id2="$(echo bar | bupstash put -k "$PUT_KEY" -)"

  bupstash sync --to "$SCRATCH/sync1" id="$id1"
  test 1 = "$(ls "$SCRATCH"/sync1/data | expr $(wc -l))"
  bupstash sync --to "$SCRATCH/sync1" id="$id2"
  test 2 = "$(ls "$SCRATCH"/sync1/data | expr $(wc -l))"
  
  bupstash sync --to "$SCRATCH/sync2"
  test 2 = "$(ls "$SCRATCH"/sync1/data | expr $(wc -l))"

  bupstash gc -r "$SCRATCH/sync1"
  bupstash gc -r "$SCRATCH/sync2"
  test 2 = $(bupstash list -r "$SCRATCH/sync1" | expr $(wc -l))
  test 2 = $(bupstash list -r "$SCRATCH/sync2" | expr $(wc -l))
}

@test "exec with locks" {
  if ! test -d "${BUPSTASH_REPOSITORY:-}"
  then
    skip "test needs a local repository"
  fi
  ls $BUPSTASH_REPOSITORY
  bupstash exec-with-locks sh -c \
    "rmdir \"$BUPSTASH_REPOSITORY/items\" && sleep 0.5 && mkdir \"$BUPSTASH_REPOSITORY/items\"" &
  sleep 0.2
  bupstash put -q -e echo foo
}

@test "parallel thrash" {
  
  if ! ps --version | grep -q procps-ng
  then
    skip "test requires procps-ng"
  fi

  which bwrap > /dev/null || skip bwrap missing
  # Use bwrap to help ensure proper cleanup and protect the host processes from kills.
  bwrap \
    --die-with-parent \
    --unshare-pid \
    --dev-bind / / \
    bash "$BATS_TEST_DIRNAME"/parallel-thrash.sh
}

@test "s3 parallel thrash" {
  if ! ps --version | grep -q procps-ng
  then
    skip "test requires procps-ng"
  fi
  which bwrap > /dev/null || skip bwrap missing
  which bupstash-s3-storage > /dev/null || skip "bupstash-s3-storage missing"
  which minio > /dev/null || skip "minio missing"
  which mc > /dev/null || skip "mc missing"
  
  # This test uses a lot of file descriptors.
  ulimit -n $(ulimit -Hn)
  # Use bwrap to help ensure proper cleanup and protect the host processes from kills.
  bwrap \
    --die-with-parent \
    --unshare-net \
    --unshare-pid \
    --dev-bind / / \
    -- $(which bash) "$BATS_TEST_DIRNAME"/s3-parallel-thrash.sh
}

@test "ignore permission errors on parent path elements" {
  # Create something readable that is always backed up such that the operation
  # is still considered succesful while other paths could not be backed up.
  mkdir "$SCRATCH/userdir"
  # Lacking test code to create files owned by another user,
  # assume /root/ is not readable.

  # The indexer must handle EACCES in any path element, i.e. gracefully stop at
  # the first inaccessible parent directory.
  id=$(bupstash put --ignore-permission-errors :: "$SCRATCH/userdir" /root/rootfile)
  rootuid=$(bupstash list-contents --format=jsonl1 --pick root/ id=$id | jq .uid)
  test 0 = $rootuid
}
