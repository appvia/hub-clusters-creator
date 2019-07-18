#
#  vim:ts=2:sw=2:et
#
NAME=hub-bootstrap
AUTHOR ?= appvia
REGISTRY ?= quay.io
VERSION ?= latest

.PHONY: build test docker

default: build

build:
	@echo "--> Building the GEM"
	gem build hub-clusters-creator.gemspec

docker:
	@echo "--> Building the docker image: ${REGISTRY}/${AUTHOR}/${NAME}:${VERSION}"
	@(cd docker && docker build -t ${REGISTRY}/${AUTHOR}/${NAME}:${VERSION} .)

push:
	@echo "--> Pushing the image to respository"
	docker push ${REGISTRY}/${AUTHOR}/${NAME}:${VERSION}

clean:
	@echo "--> Performing a cleanup"
	@docker rmi -f ${REGISTRY}/${AUTHOR}/${NAME}:${VERSION} 2>/dev/null
	@rm -f *.gem
