#!/bin/sh
DFLAGS="-preview=systemVariables -preview=dip1000"
dmd $DFLAGS -unittest -g -betterC -I=src -i -run test_betterc.d
