#!/bin/sh
echo "Deleting all Latex temporaries!"
pwd
rm -f ./*.aux ./*.log ./*.out ./*.toc ./*.lof ./*.lot
rm -f ./*.nav ./*.snm ./*.vrb
rm -f ./*.bbl ./*.blg ./*.bcf ./*.run.xml
rm -f ./*.idx ./*.ind ./*.ilg
rm -f ./*.fls ./*.fdb_latexmk ./*.synctex.gz ./*.synctex
rm -f ./*.gz
