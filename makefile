# start project configuration
name := sink
buildDir := build
packages := 
orgPath := github.com/tychoish
projectPath := $(orgPath)/$(name)
# end project configuration


# start linting configuration
#   package, testing, and linter dependencies specified
#   separately. This is a temporary solution: eventually we should
#   vendorize all of these dependencies.
lintDeps := github.com/alecthomas/gometalinter
#   include test files and give linters 40s to run to avoid timeouts
lintArgs := --tests --deadline=1m --vendor --concurrency=4
#   gotype produces false positives because it reads .a files which
#   are rarely up to date.
lintArgs += --disable="gotype" --disable="gas"
lintArgs += --skip="build" --skip="buildscripts"
#   enable and configure additional linters
lintArgs += --enable="goimports"
lintArgs += --linter='misspell:misspell ./*.go:PATH:LINE:COL:MESSAGE' --enable=misspell
lintArgs += --line-length=100 --dupl-threshold=150 --cyclo-over=15
#   the gotype linter has an imperfect compilation simulator and
#   produces the following false postive errors:
lintArgs += --exclude="error: could not import github.com/mongodb/greenbay"
#   some test cases are structurally similar, and lead to dupl linter
#   warnings, but are important to maintain separately, and would be
#   difficult to test without a much more complex reflection/code
#   generation approach, so we ignore dupl errors in tests.
lintArgs += --exclude="warning: duplicate of .*_test.go"
#   go lint warns on an error in docstring format, erroneously because
#   it doesn't consider the entire package.
lintArgs += --exclude="warning: package comment should be of the form \"Package .* ...\""
#   known issues that the linter picks up that are not relevant in our cases
lintArgs += --exclude="file is not goimported" # top-level mains aren't imported
lintArgs += --exclude="error return value not checked .defer.*"
# end linting configuration


# start dependency installation tools
#   implementation details for being able to lazily install dependencies
gopath := $(shell go env GOPATH)
lintDeps := $(addprefix $(gopath)/src/,$(lintDeps))
srcFiles := makefile $(shell find . -name "*.go" -not -path "./$(buildDir)/*" -not -name "*_test.go" -not -path "./buildscripts/*" )
testSrcFiles := makefile $(shell find . -name "*.go" -not -path "./$(buildDir)/*")
testOutput := $(foreach target,$(packages),$(buildDir)/test.$(target).out)
raceOutput := $(foreach target,$(packages),$(buildDir)/race.$(target).out)
coverageOutput := $(foreach target,$(packages),$(buildDir)/coverage.$(target).out)
coverageHtmlOutput := $(foreach target,$(packages),$(buildDir)/coverage.$(target).html)
$(gopath)/src/%:
	@-[ ! -d $(gopath) ] && mkdir -p $(gopath) || true
	go get $(subst $(gopath)/src/,,$@)
# end dependency installation tools


# implementation details for building the binary and creating a
# convienent link in the working directory
define crossCompile
	@$(vendorGopath) ./$(buildDir)/build-cross-compile -buildName=$* -ldflags="-X=github.com/tychoish/sink.BuildRevision=`git rev-parse HEAD`" -goBinary="`which go`" -output=$@
endef
$(name):$(buildDir)/$(name)
	@[ -e $@ ] || ln -s $<
$(buildDir)/$(name):$(srcFiles)
	$(vendorGopath) go build -ldflags "-X github.com/tychoish/sink.BuildRevision=`git rev-parse HEAD`" -o $@ main/$(name).go
$(buildDir)/$(name).race:$(srcFiles)
	$(vendorGopath) go build -race -ldflags "-X github.com/tychoish/sink.BuildRevision=`git rev-parse HEAD`" -o $@ main/$(name).go
# end dependency installation tools


# distribution targets and implementation
distContents := $(agentBuildDir) $(clientBuildDir) $(distArtifacts)
distTestContents := $(foreach pkg,$(packages),$(buildDir)/test.$(pkg) $(buildDir)/race.$(pkg))
$(buildDir)/build-cross-compile:buildscripts/build-cross-compile.go
	@mkdir -p $(buildDir)
	go build -o $@ $<
$(buildDir)/make-tarball:buildscripts/make-tarball.go $(buildDir)/render-gopath
	$(vendorGopath) go build -o $@ $<
dist:$(buildDir)/dist.tar.gz
dist-test:$(buildDir)/dist-test.tar.gz
dist-race: $(buildDir)/dist-race.tar.gz
dist-source:$(buildDir)/dist-source.tar.gz
$(buildDir)/dist.tar.gz:$(buildDir)/make-tarball $(binaries)
	./$< --name $@ --prefix $(name) $(foreach item,$(binaries) $(distContents),--item $(item))
$(buildDir)/dist-race.tar.gz:$(buildDir)/make-tarball makefile $(raceBinaries)
	./$< -name $@ --prefix $(name)-race $(foreach item,$(raceBinaries) $(distContents),--item $(item))
$(buildDir)/dist-test.tar.gz:$(buildDir)/make-tarball makefile $(binaries) $(raceBinaries)
	./$< -name $@ --prefix $(name)-tests $(foreach item,$(distContents) $(distTestContents),--item $(item)) $(foreach item,,--item $(item))
$(buildDir)/dist-source.tar.gz:$(buildDir)/make-tarball $(srcFiles) $(testSrcFiles) makefile
	./$< --name $@ --prefix $(name) $(subst $(name),,$(foreach pkg,$(packages),--item ./$(subst -,/,$(pkg)))) --item ./scripts --item makefile --exclude "$(name)" --exclude "^.git/" --exclude "$(buildDir)/"
# end main build


# userfacing targets for basic build and development operations
lint:$(lintDeps)
	@-$(gopath)/bin/gometalinter --install >/dev/null
	$(gopath)/bin/gometalinter $(lintArgs) ./...
build:$(buildDir)/$(name)
build-race:$(buildDir)/$(name).race
test:$(foreach target,$(packages),test-$(target))
race:$(foreach target,$(packages),race-$(target))
coverage:$(coverageOutput)
coverage-html:$(coverageHtmlOutput)
list-tests:
	@echo -e "test targets:" $(foreach target,$(packages),\\n\\ttest-$(target))
list-race:
	@echo -e "test (race detector) targets:" $(foreach target,$(packages),\\n\\trace-$(target))
phony += lint lint-deps build build-race race test coverage coverage-html list-race list-tests
.PRECIOUS: $(testOutput) $(raceOutput) $(coverageOutput) $(coverageHtmlOutput)
.PRECIOUS: $(foreach target,$(packages),$(buildDir)/test.$(target))
.PRECIOUS: $(foreach target,$(packages),$(buildDir)/race.$(target))
# end front-ends


# convenience targets for runing tests and coverage tasks on a
# specific package.
race-%:$(buildDir)/output.%.race
	@grep -s -q -e "^PASS" $< && ! grep -s -q "^WARNING: DATA RACE" $<
test-%:$(buildDir)/output.%.test
	@grep -s -q -e "^PASS" $<
coverage-%:$(buildDir)/output.%.coverage
	@grep -s -q -e "^PASS" $<
html-coverage-%:$(buildDir)/output.%.coverage $(buildDir)/output.%.coverage.html
	@grep -s -q -e "^PASS" $<
# end convienence targets


# start vendoring configuration
#    begin with configuration of dependencies
vendorDeps := github.com/Masterminds/glide
vendorDeps := $(addprefix $(gopath)/src/,$(vendorDeps))
vendor-deps:$(vendorDeps)
#   this allows us to store our vendored code in vendor and use
#   symlinks to support vendored code both in the legacy style and with
#   new-style vendor directories. When this codebase can drop support
#   for go1.4, we can delete most of this.
-include $(buildDir)/makefile.vendor
nestedVendored := vendor/github.com/tychoish/grip
nestedVendored += vendor/github.com/mongodb/amboy
nestedVendored += vendor/github.com/mongodb/amboy/vendor/github.com/tychoish/gimlet
nestedVendored := $(foreach project,$(nestedVendored),$(project)/build/vendor)
$(buildDir)/makefile.vendor:$(buildDir)/render-gopath makefile
	@mkdir -p $(buildDir)
	@echo "vendorGopath := \$$(shell \$$(buildDir)/render-gopath $(nestedVendored))" >| $@
#   targets for the directory components and manipulating vendored files.
vendor-sync:$(vendorDeps)
	glide install -s
vendor-clean:
	rm -rf vendor/github.com/stretchr/testify/vendor/
	rm -rf vendor/github.com/mongodb/amboy/vendor/github.com/tychoish/grip/
	rm -rf vendor/github.com/mongodb/amboy/vendor/golang.org/x/net/
	rm -rf vendor/github.com/tychoish/gimlet/vendor/github.com/stretchr/
	rm -rf vendor/github.com/tychoish/gimlet/vendor/github.com/davecgh/
	rm -rf vendor/github.com/tychoish/gimlet/vendor/github.com/pmezard/
	rm -rf vendor/github.com/tychoish/gimlet/vendor/github.com/tychoish/grip/
	find vendor/ -name "*.gif" -o -name "*.gz" -o -name "*.png" -o -name "*.ico" -o -name "*testdata*"| xargs rm -rf
change-go-version:
	rm -rf $(buildDir)/make-vendor $(buildDir)/render-gopath
	@$(MAKE) $(makeArgs) vendor > /dev/null 2>&1
vendor:$(buildDir)/vendor/src
	@$(MAKE) $(makeArgs) -C vendor/github.com/tychoish/grip $@
	@$(MAKE) $(makeArgs) -k -C vendor/github.com/mongodb/amboy $@
$(buildDir)/vendor/src:$(buildDir)/make-vendor $(buildDir)/render-gopath
	@./$(buildDir)/make-vendor
#   targets to build the small programs used to support vendoring.
$(buildDir)/make-vendor:buildscripts/make-vendor.go
	@mkdir -p $(buildDir)
	go build -o $@ $<
$(buildDir)/render-gopath:buildscripts/render-gopath.go
	@mkdir -p $(buildDir)
	go build -o $@ $<
#   define dependencies for buildscripts
buildscripts/make-vendor.go:buildscripts/vendoring/vendoring.go
buildscripts/render-gopath.go:buildscripts/vendoring/vendoring.go
#   add phony targets
phony += vendor vendor-deps vendor-clean vendor-sync change-go-version
# end vendoring tooling configuration


# start test and coverage artifacts
#    This varable includes everything that the tests actually need to
#    run. (The "build" target is intentional and makes these targetsb
#    rerun as expected.)
testRunDeps := $(name)
testTimeout := --test.timeout=20m
testArgs := -test.v $(testTimeout)
#  targets to compile
$(buildDir)/test.%:$(testSrcFiles)
	$(vendorGopath) go test $(if $(DISABLE_COVERAGE),,-covermode=count) -c -o $@ ./$(subst -,/,$*)
$(buildDir)/race.%:$(testSrcFiles)
	$(vendorGopath) go test -race -c -o $@ ./$(subst -,/,$*)
#  targets to run any tests in the top-level package
$(buildDir)/test.$(name):$(testSrcFiles)
	$(vendorGopath) go test $(if $(DISABLE_COVERAGE),,-covermode=count) -c -o $@ ./
$(buildDir)/race.$(name):$(testSrcFiles)
	$(vendorGopath) go test -race -c -o $@ ./
#  targets to run the tests and report the output
$(buildDir)/output.%.test:$(buildDir)/test.% .FORCE
	./$< $(testArgs) 2>&1 | tee $@
$(buildDir)/output.%.race:$(buildDir)/race.% .FORCE
	./$< $(testArgs) 2>&1 | tee $@
#  targets to process and generate coverage reports
$(buildDir)/output.%.coverage:$(buildDir)/test.% .FORCE
	./$< $(testTimeout) -test.coverprofile=$@ || true
	@-[ -f $@ ] && go tool cover -func=$@ | sed 's%$(projectPath)/%%' | column -t
$(buildDir)/output.%.coverage.html:$(buildDir)/output.%.coverage
	$(vendorGopath) go tool cover -html=$< -o $@
# end test and coverage artifacts

# clean and other utility targets
clean:
	rm -rf $(lintDeps) $(buildDir)/test.* $(buildDir)/coverage.* $(buildDir)/race.* $(name) $(buildDir)/$(name)
phony += clean
# end dependency targets

# configure phony targets
.PHONY:$(phony)
