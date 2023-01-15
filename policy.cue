predicateType: "https://slsa.dev/provenance/v0.2"
predicate: {
  builder: {
    id: =~"^https://github.com/slsa-framework/slsa-github-generator/.github/workflows/generator_container_slsa3.yml@refs/tags/v[0-9]+.[0-9]+.[0-9]+$"
  }
  invocation: {
    configSource: {
      entryPoint: ".github/workflows/generic-container.yml"
      uri: =~"^git\\+https://github.com/mchmarny/s3cme@refs/tags/v[0-9]+.[0-9]+.[0-9]+$"
    }
  }
}