all: docs build

build:
	dzil build

install:
	cd Text-Conflux && cpanm .

docs:
	podselect lib/Text/Conflux.pm > README.pod
