#!/usr/bin/env bash
set -euo pipefail
name=$1 actual=$2 reference=$3
case $name in
    json)
        jq -S -c . "$actual" > "$actual.canonical"
        cmp "$actual.canonical" "$reference" ;;
    n-body|spectral-norm)
        paste "$reference" "$actual" | awk 'NF!=2{exit 1}{for(i=1;i<=2;i++)if($i!~/^-?[0-9]+([.][0-9]+)?([eE][-+]?[0-9]+)?$/)exit 1;d=$1-$2;if(d<0)d=-d;a=$1;if(a<0)a=-a;if(d>1e-8+1e-8*a)exit 1}'
        [[ $(wc -l < "$actual") == $(wc -l < "$reference") ]] ;;
    *) cmp "$actual" "$reference" ;;
esac
