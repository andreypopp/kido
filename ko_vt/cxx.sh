#!/bin/sh
case $(uname -s) in
  Darwin) echo -lc++ ;;
  *) echo -lstdc++ ;;
esac
