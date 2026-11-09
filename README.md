# PSSSourceSGML

For 1981-1997, Hansard was only published as SGML, not XML. `PSSSourceSGML` downloads those SGML files and converts each one to XML, so those years can be parsed by `PSSConvert` the same way as the rest of the corpus. It's one of four submodules that make up the [ParlinfoSpeechScraper](../../) pipeline.

## Output layout

Given an output directory (`output/` by default), files land in:

```
output/source_sgml/<house>/
├── sgmls/<year>/<year>_<month>_<day>.sgm   # downloaded sgml files
├── xmls/...xml                              # converted xml files
└── logs/                                    # log output
```
