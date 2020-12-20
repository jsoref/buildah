#!/usr/bin/env bats

load helpers

@test "pull-flags-order-verification" {
  run_buildah 125 pull image1 --tls-verify
  check_options_flag_err "--tls-verify"

  run_buildah 125 pull image1 --authfile=/tmp/somefile
  check_options_flag_err "--authfile=/tmp/somefile"

  run_buildah 125 pull image1 -q --cred bla:bla --authfile=/tmp/somefile
  check_options_flag_err "-q"
}

@test "pull-blocked" {
  run_buildah 125 --registries-conf ${TESTSDIR}/registries.conf.block pull --signature-policy ${TESTSDIR}/policy.json docker.io/alpine
  expect_output --substring "is blocked by configuration"

  run_buildah --retry --registries-conf ${TESTSDIR}/registries.conf       pull --signature-policy ${TESTSDIR}/policy.json docker.io/alpine
}

@test "pull-from-registry" {
  run_buildah --retry pull --registries-conf ${TESTSDIR}/registries.conf --signature-policy ${TESTSDIR}/policy.json busybox:glibc
  run_buildah pull --registries-conf ${TESTSDIR}/registries.conf --signature-policy ${TESTSDIR}/policy.json busybox
  run_buildah images --format "{{.Name}}:{{.Tag}}"
  expect_output --substring "busybox:glibc"
  expect_output --substring "busybox:latest"

  run_buildah --retry pull --registries-conf ${TESTSDIR}/registries.conf --signature-policy ${TESTSDIR}/policy.json quay.io/libpod/alpine_nginx:latest
  run_buildah images --format "{{.Name}}:{{.Tag}}"
  expect_output --substring "alpine_nginx:latest"

  run_buildah rmi quay.io/libpod/alpine_nginx:latest
  run_buildah --retry pull --registries-conf ${TESTSDIR}/registries.conf --signature-policy ${TESTSDIR}/policy.json quay.io/libpod/alpine_nginx
  run_buildah images --format "{{.Name}}:{{.Tag}}"
  expect_output --substring "alpine_nginx:latest"

  run_buildah --retry pull --registries-conf ${TESTSDIR}/registries.conf --signature-policy ${TESTSDIR}/policy.json alpine@sha256:e9a2035f9d0d7cee1cdd445f5bfa0c5c646455ee26f14565dce23cf2d2de7570
  run_buildah 125 pull --registries-conf ${TESTSDIR}/registries.conf --signature-policy ${TESTSDIR}/policy.json fakeimage/fortest
  run_buildah images --format "{{.Name}}:{{.Tag}}"
  [[ ! "$output" =~ "fakeimage/fortest" ]]
}

@test "pull-from-docker-archive" {
  run_buildah --retry pull --signature-policy ${TESTSDIR}/policy.json alpine
  run_buildah push --signature-policy ${TESTSDIR}/policy.json docker.io/library/alpine:latest docker-archive:${TESTDIR}/alp.tar:alpine:latest
  run_buildah rmi alpine
  run_buildah --retry pull --signature-policy ${TESTSDIR}/policy.json docker-archive:${TESTDIR}/alp.tar
  run_buildah images --format "{{.Name}}:{{.Tag}}"
  expect_output --substring "alpine"
  run_buildah 125 pull --all-tags --signature-policy ${TESTSDIR}/policy.json docker-archive:${TESTDIR}/alp.tar
  expect_output "Non-docker transport is not supported, for --all-tags pulling"
}

@test "pull-from-oci-archive" {
  run_buildah --retry pull --signature-policy ${TESTSDIR}/policy.json alpine
  run_buildah push --signature-policy ${TESTSDIR}/policy.json docker.io/library/alpine:latest oci-archive:${TESTDIR}/alp.tar:alpine
  run_buildah rmi alpine
  run_buildah pull --signature-policy ${TESTSDIR}/policy.json oci-archive:${TESTDIR}/alp.tar
  run_buildah images --format "{{.Name}}:{{.Tag}}"
  expect_output --substring "alpine"
  run_buildah 125 pull --all-tags --signature-policy ${TESTSDIR}/policy.json oci-archive:${TESTDIR}/alp.tar
  expect_output "Non-docker transport is not supported, for --all-tags pulling"
}

@test "pull-from-local-directory" {
  mkdir ${TESTDIR}/buildahtest
  run_buildah --retry pull --signature-policy ${TESTSDIR}/policy.json alpine
  run_buildah push --signature-policy ${TESTSDIR}/policy.json docker.io/library/alpine:latest dir:${TESTDIR}/buildahtest
  run_buildah rmi alpine
  run_buildah pull --signature-policy ${TESTSDIR}/policy.json dir:${TESTDIR}/buildahtest
  run_buildah images --format "{{.Name}}:{{.Tag}}"
  expect_output --substring "localhost${TESTDIR}/buildahtest:latest"
  run_buildah 125 pull --all-tags --signature-policy ${TESTSDIR}/policy.json dir:${TESTDIR}/buildahtest
  expect_output "Non-docker transport is not supported, for --all-tags pulling"
}

@test "pull-from-docker-daemon" {
  run systemctl status docker
  if [[ ! "$output" =~ "active (running)" ]]
  then
     skip "Skip the test as docker services is not running"
  fi

  run systemctl start docker
  echo "$output"
  [ "$status" -eq 0 ]
  run docker pull alpine
  echo "$output"
  [ "$status" -eq 0 ]
  run_buildah pull --signature-policy ${TESTSDIR}/policy.json docker-daemon:docker.io/library/alpine:latest
  run_buildah images --format "{{.Name}}:{{.Tag}}"
  expect_output --substring "alpine:latest"
  run_buildah rmi alpine
  run_buildah 125 pull --all-tags --signature-policy ${TESTSDIR}/policy.json docker-daemon:docker.io/library/alpine:latest
  expect_output --substring "Non-docker transport is not supported, for --all-tags pulling"
}

@test "pull-all-tags" {
  declare -a tags=(0.9 0.9.1 1.1 alpha beta gamma2.0 latest)

  # setup: pull alpine, and push it repeatedly to localhost using those tags
  opts="--signature-policy ${TESTSDIR}/policy.json --tls-verify=false --creds testuser:testpassword"
  run_buildah --retry pull --quiet --signature-policy ${TESTSDIR}/policy.json alpine
  for tag in "${tags[@]}"; do
      run_buildah push $opts alpine localhost:5000/myalpine:$tag
  done

  run_buildah images -q
  expect_line_count 1 "There's only one actual image ID"
  alpine_iid=$output

  # Remove it, and confirm.
  run_buildah rmi alpine
  run_buildah images -q
  expect_output "" "After buildah rmi, there are no locally stored images"

  # Now pull with --all-tags, and confirm that we see all expected tag strings
  run_buildah pull $opts --all-tags localhost:5000/myalpine
  for tag in "${tags[@]}"; do
      expect_output --substring "Pulling localhost:5000/myalpine:$tag"
  done

  # Confirm that 'images -a' lists all of them. <Brackets> help confirm
  # that tag names are exact, e.g we don't confuse 0.9 and 0.9.1
  run_buildah images -a --format '<{{.Tag}}>'
  expect_line_count "${#tags[@]}" "number of tagged images"
  for tag in "${tags[@]}"; do
      expect_output --substring "<$tag>"
  done

  # Finally, make sure that there's actually one and exactly one image
  run_buildah images -q
  expect_output $alpine_iid "Pulled image has the same IID as original alpine"
}

@test "pull-from-oci-directory" {
  run_buildah --retry pull --signature-policy ${TESTSDIR}/policy.json alpine
  run_buildah push --signature-policy ${TESTSDIR}/policy.json docker.io/library/alpine:latest oci:${TESTDIR}/alpine
  run_buildah rmi alpine
  run_buildah pull --signature-policy ${TESTSDIR}/policy.json oci:${TESTDIR}/alpine
  run_buildah images --format "{{.Name}}:{{.Tag}}"
  expect_output --substring "localhost${TESTDIR}/alpine:latest"
  run_buildah 125 pull --all-tags --signature-policy ${TESTSDIR}/policy.json oci:${TESTDIR}/alpine
  expect_output "Non-docker transport is not supported, for --all-tags pulling"
}

@test "pull-denied-by-registry-sources" {
  export BUILD_REGISTRY_SOURCES='{"blockedRegistries": ["docker.io"]}'

  run_buildah 125 pull --signature-policy ${TESTSDIR}/policy.json --registries-conf ${TESTSDIR}/registries.conf.hub --quiet busybox
  expect_output --substring 'pull from registry at "docker.io" denied by policy: it is in the blocked registries list'

  run_buildah 125 pull --signature-policy ${TESTSDIR}/policy.json --registries-conf ${TESTSDIR}/registries.conf.hub --quiet busybox
  expect_output --substring 'pull from registry at "docker.io" denied by policy: it is in the blocked registries list'

  export BUILD_REGISTRY_SOURCES='{"allowedRegistries": ["some-other-registry.example.com"]}'

  run_buildah 125 pull --signature-policy ${TESTSDIR}/policy.json --registries-conf ${TESTSDIR}/registries.conf.hub --quiet busybox
  expect_output --substring 'pull from registry at "docker.io" denied by policy: not in allowed registries list'

  run_buildah 125 pull --signature-policy ${TESTSDIR}/policy.json --registries-conf ${TESTSDIR}/registries.conf.hub --quiet busybox
  expect_output --substring 'pull from registry at "docker.io" denied by policy: not in allowed registries list'
}

@test "pull should fail with nonexist authfile" {
  run_buildah 125 pull --authfile /tmp/nonexist --signature-policy ${TESTSDIR}/policy.json alpine
}

@test "pull encrypted local image" {
  _prefetch busybox
  mkdir ${TESTDIR}/tmp
  openssl genrsa -out ${TESTDIR}/tmp/mykey.pem 1024
  openssl genrsa -out ${TESTDIR}/tmp/mykey2.pem 1024
  openssl rsa -in ${TESTDIR}/tmp/mykey.pem -pubout > ${TESTDIR}/tmp/mykey.pub
  run_buildah push --signature-policy ${TESTSDIR}/policy.json --encryption-key jwe:${TESTDIR}/tmp/mykey.pub busybox  oci:${TESTDIR}/tmp/busybox_enc

  # Try to pull encrypted image without key should fail
  run_buildah 125 pull --signature-policy ${TESTSDIR}/policy.json oci:${TESTDIR}/tmp/busybox_enc
  expect_output --substring "Error decrypting layer .* missing private key needed for decryption"

  # Try to pull encrypted image with wrong key should fail
  run_buildah 125 pull --signature-policy ${TESTSDIR}/policy.json --decryption-key ${TESTDIR}/tmp/mykey2.pem oci:${TESTDIR}/tmp/busybox_enc
  expect_output --substring "Error decrypting layer .* no suitable key unwrapper found or none of the private keys could be used for decryption"

  # Providing the right key should succeed
  run_buildah pull --signature-policy ${TESTSDIR}/policy.json --decryption-key ${TESTDIR}/tmp/mykey.pem oci:${TESTDIR}/tmp/busybox_enc

  rm -rf ${TESTDIR}/tmp
}

@test "pull encrypted registry image" {
  _prefetch busybox
  mkdir ${TESTDIR}/tmp
  openssl genrsa -out ${TESTDIR}/tmp/mykey.pem 1024
  openssl genrsa -out ${TESTDIR}/tmp/mykey2.pem 1024
  openssl rsa -in ${TESTDIR}/tmp/mykey.pem -pubout > ${TESTDIR}/tmp/mykey.pub
  run_buildah push --signature-policy ${TESTSDIR}/policy.json --tls-verify=false --creds testuser:testpassword --encryption-key jwe:${TESTDIR}/tmp/mykey.pub busybox docker://localhost:5000/buildah/busybox_encrypted:latest

  # Try to pull encrypted image without key should fail
  run_buildah 125 pull --signature-policy ${TESTSDIR}/policy.json --tls-verify=false --creds testuser:testpassword docker://localhost:5000/buildah/busybox_encrypted:latest
  expect_output --substring "Error decrypting layer .* missing private key needed for decryption"

  # Try to pull encrypted image with wrong key should fail, with diff. msg
  run_buildah 125 pull --signature-policy ${TESTSDIR}/policy.json --tls-verify=false --creds testuser:testpassword --decryption-key ${TESTDIR}/tmp/mykey2.pem docker://localhost:5000/buildah/busybox_encrypted:latest
  expect_output --substring "Error decrypting layer .* no suitable key unwrapper found or none of the private keys could be used for decryption"

  # Providing the right key should succeed
  run_buildah pull --signature-policy ${TESTSDIR}/policy.json --tls-verify=false --creds testuser:testpassword --decryption-key ${TESTDIR}/tmp/mykey.pem docker://localhost:5000/buildah/busybox_encrypted:latest

  run_buildah rmi localhost:5000/buildah/busybox_encrypted:latest

  rm -rf ${TESTDIR}/tmp
}

@test "pull encrypted registry image from commit" {
 _prefetch busybox
  mkdir ${TESTDIR}/tmp
  openssl genrsa -out ${TESTDIR}/tmp/mykey.pem 1024
  openssl genrsa -out ${TESTDIR}/tmp/mykey2.pem 1024
  openssl rsa -in ${TESTDIR}/tmp/mykey.pem -pubout > ${TESTDIR}/tmp/mykey.pub
  run_buildah from --quiet --pull=false --signature-policy ${TESTSDIR}/policy.json busybox
  cid=$output
  run_buildah commit --iidfile /dev/null --tls-verify=false --creds testuser:testpassword --signature-policy ${TESTSDIR}/policy.json --encryption-key jwe:${TESTDIR}/tmp/mykey.pub -q $cid docker://localhost:5000/buildah/busybox_encrypted:latest

  # Try to pull encrypted image without key should fail
  run_buildah 125 pull --signature-policy ${TESTSDIR}/policy.json --tls-verify=false --creds testuser:testpassword docker://localhost:5000/buildah/busybox_encrypted:latest
  expect_output --substring "Error decrypting layer .* missing private key needed for decryption"

  # Try to pull encrypted image with wrong key should fail
  run_buildah 125 pull --signature-policy ${TESTSDIR}/policy.json --tls-verify=false --creds testuser:testpassword --decryption-key ${TESTDIR}/tmp/mykey2.pem docker://localhost:5000/buildah/busybox_encrypted:latest
  expect_output --substring "Error decrypting layer .* no suitable key unwrapper found or none of the private keys could be used for decryption"

  # Providing the right key should succeed
  run_buildah pull --signature-policy ${TESTSDIR}/policy.json --tls-verify=false --creds testuser:testpassword --decryption-key ${TESTDIR}/tmp/mykey.pem docker://localhost:5000/buildah/busybox_encrypted:latest

  run_buildah rmi localhost:5000/buildah/busybox_encrypted:latest

  rm -rf ${TESTDIR}/tmp
}

@test "pull image into a full storage" {
  mkdir /tmp/buildah-test
  mount -t tmpfs -o size=5M tmpfs /tmp/buildah-test
  run dd if=/dev/urandom of=/tmp/buildah-test/full
  run_buildah 125 --root=/tmp/buildah-test pull --signature-policy ${TESTSDIR}/policy.json alpine
  expect_output --substring "no space left on device"
  umount /tmp/buildah-test
  rm -rf /tmp/buildah-test
}

@test "pull with authfile" {
  _prefetch busybox
  mkdir ${TESTDIR}/tmp
  run_buildah push --creds testuser:testpassword --tls-verify=false busybox docker://localhost:5000/buildah/busybox:latest
  run_buildah login --authfile ${TESTDIR}/tmp/test.auth --username testuser --password testpassword --tls-verify=false localhost:5000
  run_buildah pull --authfile ${TESTDIR}/tmp/test.auth --tls-verify=false docker://localhost:5000/buildah/busybox:latest
  run_buildah rmi localhost:5000/buildah/busybox:latest

  rm -rf ${TESTDIR}/tmp
}

@test "pull quietly" {
  run_buildah pull -q busybox
  iid=$output
  run_buildah rmi ${iid}
}

@test "pull-policy" {
  mkdir ${TESTDIR}/buildahtest
  run_buildah 125 pull --signature-policy ${TESTSDIR}/policy.json --policy bogus alpine
  expect_output --substring "unrecognized pull policy bogus"

  #  If image does not exist the never will fail
  run_buildah 125 pull -q --signature-policy ${TESTSDIR}/policy.json --policy never alpine
  expect_output --substring "could not be found locally"
  run_buildah 125 inspect alpine
  expect_output --substring "image not known"

  # create bogus alpine image
  run_buildah from --signature-policy ${TESTSDIR}/policy.json scratch
  cid=$output
  run_buildah commit -q $cid docker.io/library/alpine
  iid=$output

  #  If image does not exist the never will succeed, but iid should not change
  run_buildah pull -q --signature-policy ${TESTSDIR}/policy.json --policy never alpine
  expect_output $iid

  # Pull image by default should change the image id
  run_buildah pull -q --policy always --signature-policy ${TESTSDIR}/policy.json alpine
  if [[ $output == $iid ]]; then
      expect_output "[output should not be '$iid']"
  fi

  # Recreate image
  run_buildah commit -q $cid docker.io/library/alpine
  iid=$output

  # Make sure missing image works
  run_buildah pull -q --signature-policy ${TESTSDIR}/policy.json --policy missing alpine
  expect_output $iid

  run_buildah rmi alpine
  run_buildah pull -q --signature-policy ${TESTSDIR}/policy.json alpine
  run_buildah inspect alpine

  run_buildah rmi alpine
  run_buildah pull -q --signature-policy ${TESTSDIR}/policy.json --policy missing alpine
  run_buildah inspect alpine

  run_buildah rmi alpine
}
