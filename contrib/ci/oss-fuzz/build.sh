#!/bin/bash -eu
# Copyright (C) 2020 Richard Hughes <richard@hughsie.com>
# SPDX-License-Identifier: LGPL-2.1+

# set if unknown
if [ -z "${CC:-}" ]; then
	CC=gcc
fi
if [ -z "${CXX:-}" ]; then
	CXX=g++
fi
if [ -z "${CFLAGS:-}" ]; then
	CFLAGS=""
fi
if [ -z "${CXXFLAGS:-}" ]; then
	CXXFLAGS=""
fi
if [ -z "${WORK:-}" ]; then
	WORK="build-oss-fuzz"
	mkdir -p $WORK
fi
if [ -z "${OUT:-}" ]; then
	OUT="build-oss-fuzz/out"
	mkdir -p $OUT
fi
if [ -z "${SRC:-}" ]; then
	SRC="."
fi

# build bits of xmlb
if [ ! -d "${SRC}/libxmlb" ]; then
	git clone https://github.com/hughsie/libxmlb.git
	cd libxmlb
	ln -s src libxmlb
	cd ..
fi

# build bits of json-glib
if [ ! -d "${SRC}/json-glib" ]; then
	git clone https://gitlab.gnome.org/GNOME/json-glib.git
fi

# set up shared / static
CFLAGS="$CFLAGS -I${SRC}/contrib/ci/oss-fuzz -I${SRC}/contrib/ci/oss-fuzz/json-glib "
CFLAGS="$CFLAGS -I${SRC} -I${SRC}/libfwupd -I${SRC}/libfwupdplugin "
CFLAGS="$CFLAGS -I${SRC}/libxmlb -I${SRC}/libxmlb/libxmlb "
CFLAGS="$CFLAGS -I${SRC}/json-glib -I${SRC}/json-glib/json-glib -DJSON_COMPILATION"
CFLAGS="$CFLAGS -DJSON_COMPILATION -DGETTEXT_PACKAGE"
CFLAGS="$CFLAGS -Wno-deprecated-declarations"
PREDEPS_LDFLAGS="-Wl,-Bdynamic -ldl -lm -lc -pthread -lrt -lpthread"
DEPS="gmodule-2.0 glib-2.0 gio-unix-2.0 gobject-2.0"
# json-glib-1.0"
if [ -z "${LIB_FUZZING_ENGINE:-}" ]; then
	BUILD_CFLAGS="$CFLAGS `pkg-config --cflags $DEPS`"
	BUILD_LDFLAGS="$PREDEPS_LDFLAGS `pkg-config --libs $DEPS`"
else
	BUILD_CFLAGS="$CFLAGS `pkg-config --static --cflags $DEPS`"
	BUILD_LDFLAGS="$PREDEPS_LDFLAGS -Wl,-static `pkg-config --static --libs $DEPS`"
fi
BUILT_OBJECTS=""

export PKG_CONFIG="`which pkg-config` --static"
PREFIX=$WORK/prefix
mkdir -p $PREFIX

# Build json-glib
pushd $SRC/json-glib
meson \
    --prefix=$PREFIX \
    --libdir=lib \
    --default-library=static \
    -Dgtk_doc=disabled \
    -Dintrospection=disabled \
    _builddir
ninja -C _builddir
ninja -C _builddir install
popd

exit 1

# json-glib
libjsonglib_srcs="\
	json-parser \
"
for obj in $libjsonglib_srcs; do
	$CC $CFLAGS $BUILD_CFLAGS -c ${SRC}/json-glib/json-glib/$obj.c -o $WORK/$obj.o
	BUILT_OBJECTS="$BUILT_OBJECTS $WORK/$obj.o"
done

# libxmlb
libxmlb_srcs="\
	xb-builder \
	xb-builder-fixup \
	xb-builder-node \
	xb-builder-source \
	xb-builder-source-ctx \
	xb-common \
	xb-machine \
	xb-node \
	xb-node-query \
	xb-opcode \
	xb-query \
	xb-query-context \
	xb-silo \
	xb-silo-export \
	xb-silo-query \
	xb-stack \
	xb-string \
	xb-value-bindings \
"
for obj in $libxmlb_srcs; do
	$CC $CFLAGS $BUILD_CFLAGS -c ${SRC}/libxmlb/libxmlb/$obj.c -o $WORK/$obj.o
	BUILT_OBJECTS="$BUILT_OBJECTS $WORK/$obj.o"
done

# libfwupd shared built objects
libfwupd_srcs="\
	fwupd-common \
	fwupd-device \
	fwupd-enums \
	fwupd-error \
	fwupd-release \
"
for obj in $libfwupd_srcs; do
	$CC $CFLAGS $BUILD_CFLAGS -c ${SRC}/libfwupd/$obj.c -o $WORK/$obj.o
	BUILT_OBJECTS="$BUILT_OBJECTS $WORK/$obj.o"
done

# libfwupdplugin shared built objects
libfwupdplugin_srcs="\
	fu-common \
	fu-common-version \
	fu-device \
	fu-device-locker \
	fu-firmware \
	fu-firmware-image \
	fu-quirks \
	fu-volume \
"
for obj in $libfwupdplugin_srcs; do
	$CC $CFLAGS $BUILD_CFLAGS -c ${SRC}/libfwupdplugin/$obj.c -o $WORK/$obj.o
	BUILT_OBJECTS="$BUILT_OBJECTS $WORK/$obj.o"
done

# dummy binary entrypoint
if [ -z "${LIB_FUZZING_ENGINE:-}" ]; then
	$CC $CFLAGS $BUILD_CFLAGS -c ${SRC}/libfwupdplugin/fu-fuzzer-main.c -o $WORK/fu-fuzzer-main.o
	BUILT_OBJECTS="$BUILT_OBJECTS $WORK/fu-fuzzer-main.o"
else
	BUILT_OBJECTS="$BUILT_OBJECTS $LIB_FUZZING_ENGINE"
fi

# we are doing insane things with GType
BUILD_CFLAGS_FUZZER_FIRMWARE="-Wno-implicit-function-declaration -Wno-int-conversion"

# DFU
fuzzer_type="dfu"
fuzzer_name="fu-${fuzzer_type}-firmware"
$CC $CFLAGS $BUILD_CFLAGS -c ${SRC}/libfwupdplugin/fu-${fuzzer_type}-firmware.c -o $WORK/$fuzzer_name.o
$CC $CFLAGS $BUILD_CFLAGS $BUILD_CFLAGS_FUZZER_FIRMWARE \
	-DGOBJECTTYPE=fu_${fuzzer_type}_firmware_new -c \
	${SRC}/libfwupdplugin/fu-fuzzer-firmware.c -o $WORK/${fuzzer_name}_fuzzer.o
$CXX $CXXFLAGS $BUILT_OBJECTS $WORK/$fuzzer_name.o $WORK/${fuzzer_name}_fuzzer.o \
	-o $OUT/${fuzzer_name}_fuzzer $BUILD_LDFLAGS
zip --junk-paths $OUT/${fuzzer_name}_fuzzer_seed_corpus.zip ${SRC}/src/fuzzing/firmware/${fuzzer_type}*
