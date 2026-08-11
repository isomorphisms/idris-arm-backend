IDRIS2 ?= idris2
ANDROID_CLANG ?= armv7a-linux-androideabi34-clang
IDRIS2_REVISION ?= f66d2a180
BACKEND_SOURCES := $(wildcard src/Backend/ARMv7/*.idr) src/RendererPrimitives.idr backend.ipkg
TEST_EXECUTABLE := build/exec/idris-arm-backend-tests
QUADRATIC_ASSEMBLY := build/exec/quadratic.android-armv7.S
OPERATIONS_ASSEMBLY := build/exec/all_operations.android-armv7.S
QUADRATIC_OBJECT := build/exec/quadratic.android-armv7.o
OPERATIONS_OBJECT := build/exec/all_operations.android-armv7.o

.PHONY: check-compiler check test update-golden driver example operations-example integration assemble shared verify-object verify

check-compiler:
	@$(IDRIS2) --version | grep -q '$(IDRIS2_REVISION)' || { echo "Expected Idris 2 revision $(IDRIS2_REVISION)"; exit 1; }

check: check-compiler
	$(IDRIS2) --typecheck backend.ipkg
	IDRIS2_PATH="$(CURDIR)/build/ttc:$${IDRIS2_PATH}" $(IDRIS2) -p idris2 -p network --source-dir tests --check tests/TestMain.idr

$(TEST_EXECUTABLE): tests/TestMain.idr $(BACKEND_SOURCES)
	IDRIS2_PATH="$(CURDIR)/build/ttc:$${IDRIS2_PATH}" $(IDRIS2) -p idris2 -p network --source-dir tests tests/TestMain.idr -o idris-arm-backend-tests

test: check $(TEST_EXECUTABLE)
	./$(TEST_EXECUTABLE) generated/evaluate_quadratic.S

update-golden: check $(TEST_EXECUTABLE)
	./$(TEST_EXECUTABLE) --update-golden generated/evaluate_quadratic.S

driver: build/exec/idris2-armv7

build/exec/idris2-armv7: $(BACKEND_SOURCES)
	$(IDRIS2) --build backend.ipkg

$(QUADRATIC_ASSEMBLY): build/exec/idris2-armv7 examples/Quadratic.idr
	IDRIS2_PATH="$(CURDIR)/build/ttc:$${IDRIS2_PATH}" ./build/exec/idris2-armv7 --cg android-armv7 --source-dir examples examples/Quadratic.idr -o quadratic

example: $(QUADRATIC_ASSEMBLY)

$(OPERATIONS_ASSEMBLY): build/exec/idris2-armv7 examples/AllOperations.idr
	IDRIS2_PATH="$(CURDIR)/build/ttc:$${IDRIS2_PATH}" ./build/exec/idris2-armv7 --cg android-armv7 --source-dir examples examples/AllOperations.idr -o all_operations

operations-example: $(OPERATIONS_ASSEMBLY)

integration: example operations-example
	grep -q '^evaluate_quadratic:' $(QUADRATIC_ASSEMBLY)
	grep -q '^exercise_operations:' $(OPERATIONS_ASSEMBLY)
	grep -q '^float32_identity:' $(OPERATIONS_ASSEMBLY)
	grep -q '^float32_first:' $(OPERATIONS_ASSEMBLY)
	grep -q 'vsub.f32' $(OPERATIONS_ASSEMBLY)
	grep -q 'vneg.f32' $(OPERATIONS_ASSEMBLY)
	grep -q 'vabs.f32' $(OPERATIONS_ASSEMBLY)
	grep -q 'vsqrt.f32' $(OPERATIONS_ASSEMBLY)
	grep -q 'vdiv.f32' $(OPERATIONS_ASSEMBLY)
	@IDRIS2_PATH="$(CURDIR)/build/ttc:$${IDRIS2_PATH}" ./build/exec/idris2-armv7 --cg android-armv7 --source-dir tests/source tests/source/InvalidIntArgument.idr -o invalid_int_argument > build/exec/invalid-int-argument.log 2>&1 || true
	grep -q 'unsupported source primitive type.*Int' build/exec/invalid-int-argument.log
	@IDRIS2_PATH="$(CURDIR)/build/ttc:$${IDRIS2_PATH}" ./build/exec/idris2-armv7 --cg android-armv7 --source-dir tests/source tests/source/InvalidResult.idr -o invalid_result > build/exec/invalid-result.log 2>&1 || true
	grep -q 'result must be RendererPrimitives.Float32' build/exec/invalid-result.log

assemble: integration
	$(ANDROID_CLANG) -c -fPIC -march=armv7-a -mthumb -mfpu=vfpv3-d16 -mfloat-abi=softfp $(QUADRATIC_ASSEMBLY) -o $(QUADRATIC_OBJECT)
	$(ANDROID_CLANG) -c -fPIC -march=armv7-a -mthumb -mfpu=vfpv3-d16 -mfloat-abi=softfp $(OPERATIONS_ASSEMBLY) -o $(OPERATIONS_OBJECT)

shared: assemble
	$(ANDROID_CLANG) -nostdlib -shared -Wl,--no-undefined -Wl,-soname,libidris_arm_leaf.so $(QUADRATIC_OBJECT) -o build/exec/libidris_arm_leaf.so

verify-object: assemble
	readelf -h $(QUADRATIC_OBJECT) | grep -q 'Class:.*ELF32'
	readelf -h $(QUADRATIC_OBJECT) | grep -q 'Machine:.*ARM'
	readelf -h $(QUADRATIC_OBJECT) | grep -q 'soft-float ABI'
	readelf -A $(QUADRATIC_OBJECT) | grep -q 'Tag_THUMB_ISA_use: Thumb-2'
	readelf -A $(QUADRATIC_OBJECT) | grep -q 'Tag_FP_arch: VFPv3-D16'
	readelf -sW $(QUADRATIC_OBJECT) | grep -q 'evaluate_quadratic'
	readelf -sW $(OPERATIONS_OBJECT) | grep -q 'exercise_operations'
	readelf -sW $(OPERATIONS_OBJECT) | grep -q 'float32_identity'
	readelf -sW $(OPERATIONS_OBJECT) | grep -q 'float32_first'

verify: test integration verify-object
