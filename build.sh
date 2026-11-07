#!/bin/sh
set -e

if [ -z "$1" ]; then
    echo "usage: ./build.sh <branch name or tag name>"
    echo "example: ./build.sh main"
    echo "example: ./build.sh v26.7.0"
    exit 1
fi

version=$1
workdir=$(pwd)

query_component() {
  component=$1
  curl -fsSL 'https://dcp.openharmony.cn/api/daily_build/build/list/component' \
    -H 'Accept: application/json, text/plain, */*' \
    -H 'Content-Type: application/json' \
    --data-raw '{"projectName":"openharmony","branch":"master","pageNum":1,"pageSize":10,"deviceLevel":"","component":"'${component}'","type":1,"startTime":"2025080100000000","endTime":"20990101235959","sortType":"","sortField":"","hardwareBoard":"","buildStatus":"success","buildFailReason":"","withDomain":1}'
}

# clean old files if exist
rm -rf *.tar.gz \
  *.tar.xz \
  ohos-sdk \
  daily_build.log \
  manifest_tag.xml \
  llvm-19 \
  node \
  node-${version}-openharmony-arm64

# setup openharmony sdk
sdk_download_url=$(query_component "ohos-sdk-public" | jq -r ".data.list.dataList[0].obsPath")
curl $sdk_download_url -o ohos-sdk-public.tar.gz
tar -zxf ohos-sdk-public.tar.gz
rm -rf daily_build.log manifest_tag.xml ohos-sdk/windows ohos-sdk/ohos
cd ohos-sdk/linux
unzip -q toolchains-*.zip
rm -rf *.zip
cd ../..

# setup LLVM-19
llvm19_download_url=$(query_component "LLVM-19" | jq -r ".data.list.dataList[0].obsPath")
curl $llvm19_download_url -o LLVM-19.tar.gz
mkdir llvm-19
tar -zxf LLVM-19.tar.gz -C llvm-19
cd llvm-19
tar -zxf llvm-linux-x86_64.tar.gz
tar -zxf ohos-sysroot.tar.gz
cd ..

git clone --branch $version --depth 1 https://github.com/nodejs/node.git
cd node

export CC="$workdir/llvm-19/llvm/bin/aarch64-unknown-linux-ohos-clang -fno-emulated-tls"
export CXX="$workdir/llvm-19/llvm/bin/aarch64-unknown-linux-ohos-clang++ -fno-emulated-tls"
export CC_host="gcc"
export CXX_host="g++"

patch -p1 < ../0001-fix-argument-list-too-long.patch \
  || echo "patch 0001 did not apply (may not be needed for $version)"

need_patch_0002_versions="^v22\."
if echo "$version" | grep -q "$need_patch_0002_versions"; then
    patch -p1 < ../0002-use-C++20-for-Node.js-core.patch
fi

export CC="$CC -Wno-error=implicit-function-declaration"
export CXX="$CXX -Wno-error=implicit-function-declaration"

# Compile budget: the free GitHub runner has only 4 cores and a hard job
# timeout, and --shared forces -fPIC across all of V8/ICU. Trim everything
# that is not needed to embed Node as a library:
#   --with-intl=none    drop ICU (hundreds of sources)
#   --without-snapshot  drop the host-arch V8 build + mksnapshot run
#   --without-npm/corepack  drop CLI packaging
CONFIGURE_ARGS="--dest-cpu=arm64 \
  --dest-os=openharmony \
  --cross-compiling \
  --shared \
  --with-intl=none \
  --without-snapshot \
  --without-npm \
  --without-corepack \
  --openssl-no-asm \
  --prefix=$workdir/node-${version}-openharmony-arm64"

# Node.js's build system enables Temporal by default when a Rust environment
# is available on the build machine.
# For details, see this PR: https://github.com/nodejs/node/pull/61806.
# However, enabling Temporal causes build failures during cross-compilation for OHOS.
# To ensure this build script works correctly on machines with Rust environments
# (such as GitHub Actions runners), Temporal is explicitly disabled here.
if ./configure --help 2>&1 | grep -q -- "--v8-disable-temporal-support"; then
    CONFIGURE_ARGS="$CONFIGURE_ARGS --v8-disable-temporal-support"
fi

# V8's largest translation units take minutes each at -O3 and -fPIC (forced by
# --shared) makes it worse; -O1 roughly halves total compile time and is plenty
# for an embedded I/O-bound JS server.
sed -i "s/'-O3'/'-O1'/g" common.gypi node.gyp
find tools/v8_gypfiles -maxdepth 1 \( -name '*.gyp' -o -name '*.gypi' \) \
  -exec sed -i "s/'-O3'/'-O1'/g" {} + 2>/dev/null || true
echo "remaining -O3 flags: $(grep -rl "'-O3'" common.gypi node.gyp tools/v8_gypfiles 2>/dev/null | wc -l)"

# Resume support: a previous (timed-out) attempt may have left a partial
# out/ dir; make can pick up where it stopped as long as sources are identical
# (same tag + same patches -> deterministic tree).
if [ -d "$workdir/out-cache" ] && [ -n "$(ls -A "$workdir/out-cache" 2>/dev/null)" ]; then
    echo "restoring partial build dir from out-cache ($(du -sh "$workdir/out-cache" | cut -f1))"
    mkdir -p out
    cp -a "$workdir/out-cache/." out/
fi

./configure $CONFIGURE_ARGS

# Run make with full output captured to a file and print a heartbeat with live
# progress every 2 minutes, so the position of the build is always visible in
# the Actions log even if the job gets killed by the timeout.
rm -f /tmp/make_full.log
JOBS=${MAKE_JOBS:-$(nproc)}
echo "make -j$JOBS on $(nproc) cores, $(free -m | awk '/Mem:/{print $7}') MB RAM available"
make -j$JOBS > /tmp/make_full.log 2>&1 &
MAKE_PID=$!
while kill -0 $MAKE_PID 2>/dev/null; do
    sleep 120
    DONE_N=$(grep -cE '(CXX|CC|LINK|SOLINK|ACTION)\((target|host)\)' /tmp/make_full.log 2>/dev/null) || DONE_N=0
    TGT_N=$(grep -cE '(CXX|CC|LINK|SOLINK|ACTION)\(target\)' /tmp/make_full.log 2>/dev/null) || TGT_N=0
    LAST=$(grep -E '(CXX|CC)\((target|host)\)' /tmp/make_full.log 2>/dev/null | tail -1 | sed 's/^ *//' | cut -c1-80)
    MEM=$(free -m | awk '/Mem:/{print $7}')
    echo "[heartbeat] all=$DONE_N target=$TGT_N mem=${MEM}MB last=$LAST"
done
RC=0
wait $MAKE_PID || RC=$?
TOTAL=$(grep -cE '(CXX|CC|LINK|SOLINK|ACTION)\(target\)' /tmp/make_full.log 2>/dev/null) || TOTAL=0
echo "make exit code: $RC, compiled targets: $TOTAL"
if [ $RC -ne 0 ]; then
    echo "=== make FAILED, last 250 lines of full log ==="
    tail -250 /tmp/make_full.log
    exit 1
fi
make install
cd ..

# code signing
$workdir/ohos-sdk/linux/toolchains/lib/binary-sign-tool sign \
  -inFile node-${version}-openharmony-arm64/bin/node \
  -outFile node-${version}-openharmony-arm64/bin/node \
  -selfSign 1

cp LICENSE node-${version}-openharmony-arm64

# verify shared library was produced
ls -l node-${version}-openharmony-arm64/lib/ || true
ln -sf libnode.so.137 node-${version}-openharmony-arm64/lib/libnode.so
if [ ! -f node-${version}-openharmony-arm64/lib/libnode.so ]; then
    echo "ERROR: libnode.so not found"
    exit 1
fi
echo "libnode.so size: $(stat -c %s node-${version}-openharmony-arm64/lib/libnode.so) bytes"

tar -zcf node-${version}-openharmony-arm64.tar.gz node-${version}-openharmony-arm64
# slim artifact: dereference symlinks so it survives Windows extraction
rm -rf out
mkdir -p out
cp -L node-${version}-openharmony-arm64/lib/libnode.so out/libnode.so
cp -rL node-${version}-openharmony-arm64/include out/include
# Ship the libc++ runtime that libnode.so was actually linked against, so the
# app never mixes it with a different SDK's copy.
LIBCXX=$(find llvm-19 -name libc++_shared.so 2>/dev/null | head -1)
if [ -n "$LIBCXX" ]; then
  cp -L "$LIBCXX" out/libc++_shared.so
  echo "bundled $LIBCXX"
else
  echo "WARN: libc++_shared.so not found in toolchain"
fi
tar -czf libnode-ohos-arm64.tar.gz -C out .
echo "=== slim artifact ==="
ls -lh libnode-ohos-arm64.tar.gz
tar -tzf libnode-ohos-arm64.tar.gz | head -5
