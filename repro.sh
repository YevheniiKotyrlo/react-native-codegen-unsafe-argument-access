#!/usr/bin/env bash
# Generates the C++ spec of ReproducerApp/specs/NativeSample.ts with react-native's codegen, nightly unless an argument
# names another version, and compiles a module built on it with clang's -Wunsafe-buffer-usage, against the folly, fmt
# and fast_float releases react-native pins, read as system headers as a library build reads its dependencies.
# Exits 1 while the generated invoker reads an argument through the raw args pointer, 0 once it does not, 2 when a step
# fails.
# Runs in node:24 with clang 16 or later and the headers folly reads:
#   apt-get install clang-19 libboost-dev libdouble-conversion-dev libgoogle-glog-dev, with CXX=clang++-19
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
cxx=${CXX:-clang++}
step() { echo "== $*"; }
fail() { echo "step failed: $*"; exit 2; }

step "toolchain"
"${cxx}" --version | head -n 1 || fail "${cxx}"
node --version || fail "node"

release=${1:-nightly}
step "install react-native@${release}"
cd "${work}" || fail "cd"
npm init -y > /dev/null || fail "npm init"
npm install --silent --no-audit --no-fund "react-native@${release}" > install.log 2>&1 || { tail -n 20 install.log; fail "npm install"; }
version=$(node -p "require('react-native/package.json').version") || fail "read version"
echo "react-native ${version}"

step "environment"
npx --yes @react-native-community/cli info || echo "@react-native-community/cli info did not run"

step "fetch the folly, fmt and fast_float react-native pins"
pins=node_modules/react-native/gradle/libs.versions.toml
folly=$(sed -n 's/^folly="\(.*\)"$/\1/p' "${pins}")
fmt=$(sed -n 's/^fmt="\(.*\)"$/\1/p' "${pins}")
fast_float=$(sed -n 's/^fastFloat="\(.*\)"$/\1/p' "${pins}")
echo "folly ${folly}, fmt ${fmt}, fast_float ${fast_float:-none pinned}"
if [[ -z "${folly}" ]] || [[ -z "${fmt}" ]]; then fail "read pins"; fi
curl -fsSL "https://github.com/facebook/folly/archive/refs/tags/v${folly}.tar.gz" | tar -xz || fail "fetch folly"
curl -fsSL "https://github.com/fmtlib/fmt/archive/refs/tags/${fmt}.tar.gz" | tar -xz || fail "fetch fmt"
fast_float_include=()
if [[ -n "${fast_float}" ]]; then
  curl -fsSL "https://github.com/fastfloat/fast_float/archive/refs/tags/v${fast_float}.tar.gz" | tar -xz || fail "fetch fast_float"
  fast_float_include=(-isystem "fast_float-${fast_float}/include")
fi

step "generate the module's C++ spec"
cp "${here}/ReproducerApp/specs/NativeSample.ts" . || fail "copy spec"
node node_modules/@react-native/codegen/lib/cli/combine/combine-js-to-schema-cli.js schema.json NativeSample.ts || fail "schema"
node node_modules/react-native/scripts/generate-specs-cli.js --platform ios --schemaPath schema.json --outputDir out --libraryName Sample --libraryType modules || fail "generate"
header=$(find out -name '*JSI.h' | head -n 1)
[[ -n "${header}" ]] || fail "no JSI header generated"
echo "generated ${header}"
grep -n 'const jsi::Value\* args\|args\[' "${header}"

step "compile a module built on the spec with -Werror -Wunsafe-buffer-usage"
cat > module.cpp << EOF
#include "${header}"

namespace facebook::react {

class SampleModule : public NativeSampleCxxSpec<SampleModule> {
 public:
  explicit SampleModule(std::shared_ptr<CallInvoker> jsInvoker) : NativeSampleCxxSpec(std::move(jsInvoker)) {}
  double add(jsi::Runtime &rt, double left, double right) { return left + right; }
};

std::shared_ptr<TurboModule> sampleModule(std::shared_ptr<CallInvoker> jsInvoker) {
  return std::make_shared<SampleModule>(std::move(jsInvoker));
}

} // namespace facebook::react
EOF
find node_modules/react-native/ReactCommon -type d -not -path '*test*' > folders.txt || fail "list ReactCommon's folders"
includes=()
while IFS= read -r folder; do includes+=(-isystem "${folder}"); done < folders.txt
"${cxx}" -std=c++20 -fsyntax-only -Werror -Wunsafe-buffer-usage \
  -DFOLLY_NO_CONFIG=1 -DFOLLY_MOBILE=1 -DFOLLY_CFG_NO_COROUTINES=1 -DFOLLY_HAVE_CLOCK_GETTIME=1 -DFOLLY_HAVE_PTHREAD=1 \
  -isystem "folly-${folly}" -isystem "fmt-${fmt}/include" "${fast_float_include[@]}" \
  -isystem node_modules/react-native/ReactCommon "${includes[@]}" module.cpp > compile.log 2>&1
status=$?
grep -m 20 'error' compile.log
if grep -q 'Wunsafe-buffer-usage' compile.log && ! grep -v 'Wunsafe-buffer-usage' compile.log | grep -q 'error:'; then
  echo "SUMMARY: react-native ${version}'s codegen reads the module's arguments through the raw args pointer"
  exit 1
fi
[[ "${status}" -eq 0 ]] || fail "the module does not compile for another reason"
echo "SUMMARY: react-native ${version}'s codegen compiles under -Wunsafe-buffer-usage"
exit 0
