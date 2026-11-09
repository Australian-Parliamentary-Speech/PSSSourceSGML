module PSSSourceSGML

using ArgParse
using ProgressMeter
using PSSUtils
using Dates
using PythonCall


#
# === Constants ===
#

const SGMLLinks::AbstractString = "HansardSGML.csv"

#
# === Types ===
# 

@enum SSGMLHouse house senate
@enum SSGMLSteps Step0 Step1 Step2 Step3

struct SSGMLPaths
    base::AbstractString
    sgmls::AbstractString
    xmls::AbstractString
    log::AbstractString
end

function SSGMLPaths(output::AbstractString, ssgml_house::AbstractString)
    base = joinpath(output, "source_sgml", ssgml_house)
    sgmls = joinpath(base, "sgmls")
    xmls = joinpath(base, "xmls")
    log = joinpath(base, "logs")
    return SSGMLPaths(base, sgmls, xmls, log)
end

function ArgParse.parse_item(::Type{SSGMLHouse}, x::AbstractString)
    for v in instances(SSGMLHouse)
        string(v) == x && return v
    end
end

#
# === Utility Functions ===
# 

function sgml2xml(fn, outputfn)
    bs4 = pyimport("bs4")
    BeautifulSoup = bs4.BeautifulSoup
    # sgml_close.py inserts the end tags the SGML omits, so BeautifulSoup does not have to guess (#9)
    pyimport("sys").path.insert(0, @__DIR__)
    sgml_close = pyimport("sgml_close")
    model = sgml_close.load_model(joinpath(@__DIR__, "sgml_model.json"))
    function xml_generate(fn, outputfn)
        sgml_content = read(fn, String)
        sgml_content = pyconvert(String, sgml_close.close_tags(sgml_content, model)[0])
        soup = BeautifulSoup(sgml_content, "lxml")
        # prettify, as the delivered inputs were made; with bs4 4.12.3 and lxml 5.3.0 (CondaPkg.toml)
        # this reproduces all 2,152 delivered 1981-1997 XML files byte for byte (#11)
        xml_content = pyconvert(String, soup.prettify())
        xml_content = replace(xml_content, "<!DOCTYPE hansard PUBLIC \"-//PARLINFO//DTD HANSARD STORAGE//EN\">" => "<!DOCTYPE hansard PUBLIC \"-//PARLINFO//DTD HANSARD STORAGE//EN\" \"hansard.dtd\">")
        open(outputfn, "w") do file
            write(file, xml_content)
        end
    end
    xml_generate(fn, outputfn)
end

#
# === CLI ===
# 

function get_args()
    s = ArgParseSettings()

    @add_arg_table! s begin
        "ssgml_house"
        required = true
        arg_type = SSGMLHouse
        help = "One of `" * join(string.(instances(SSGMLHouse)), ", ") * "`"

        "--output", "-o"
        required = false
        arg_type = AbstractString
        default = "output"
        help = "Output directory, defaults to `output/`"

        "--should_compress", "-c"
        action = :store_true
        help = "Compress output"

        "--skip", "-s"
        action = :store_true
        help = "Skip processing, usually combined with -c to compress a completed run"

    end
    return parse_args(s; as_symbols=true)
end

#
# === Main ===
#

function run(; ssgml_house::SSGMLHouse, output::AbstractString, should_compress::Bool, skip::Bool)::Bool
    paths = SSGMLPaths(output, string(ssgml_house))
    success = true
    if !skip
        if isfile(paths.base * ".tar.zst")
            @info "Decompressing previous run..."
            decompress(paths.base * ".tar.zst", paths.base, clear=true)
        end
        mkpath(paths.base)
        mkpath(paths.sgmls)
        mkpath(paths.xmls)
        mkpath(paths.log)
        logger = get_logger(paths.log)
        success &= with_logger(logger) do
            links = joinpath(dirname(@__FILE__), SGMLLinks)
            if !isfile(links)
                run(Val(Step0); paths=paths)
            end
            true
        end
        success &= run(Val(Step1); paths=paths, ssgml_house=ssgml_house)
    end
    success &= run(Val(Step3); paths=paths, should_compress=should_compress)
    return success
end

function run(::Val{Step0}; paths::SSGMLPaths)::Bool
    links_out = joinpath(dirname(@__FILE__), SGMLLinks)
    if !isfile(links_out)
        open(links_out, "w") do io
            write(io, "Sitting Day,Senate Link,Reps Link\n")
        end
    end
    for ssgml_house in instances(SSGMLHouse)
        @info "Running step 0: Searching for all $(ssgml_house) sgm files"
        chamber = string(ssgml_house) == "house" ? "reps" : "senate"
        char = chamber[1]
        @showprogress for year in 1981:1:1997, month in 1:1:12, day in 1:1:31
            date = "$(year)-$(lpad(month,2,"0"))-$(lpad(day,2,"0"))"
            link = "parlinfo.aph.gov.au/parlInfo/download/chamber/hansard$(char)/$(date)/toc_sgml/$(chamber) $(date).sgm"
            house = (chamber == "reps") ? link : ""
            senate = (chamber == "senate") ? link : ""
            success, response = get_response("https://" * link)
            if success
                open(links_out, "a") do io
                    write(io, "$(lpad(day,2,"0"))/$(lpad(month,2,"0"))/$(year),$(senate),$(house)\n")
                end
            end
        end
    end
    return true
end

function run(::Val{Step1}; paths::SSGMLPaths, ssgml_house::SSGMLHouse)::Bool
    sgmls_out = paths.sgmls
    date = string(today())
    links_in = joinpath(dirname(@__FILE__), SGMLLinks)
    lines = readlines(links_in)[2:end]
    if length(readdir(sgmls_out)) == length(lines)
        @info "Step 1 already completed as $(sgmls_out) exists and is populated, skipping..."
    else
        @info "Running step 1: Downloading $(length(lines)) sgm files..."
        @showprogress for line in lines
            date, senate, reps = split(line, ",")
            link = "https://" * ((string(ssgml_house) == "house") ? reps : senate)
            if link == "https://"
                continue
            end
            day, month, year = split(date, "/")
            out = joinpath(sgmls_out, year, "$(year)_$(lpad(month, 2, "0"))_$(lpad(day, 2, "0")).sgm")
            mkpath(dirname(out))
            download_file(link, out; filetype="text/sgml")
        end
    end
    return run(Val(Step2); paths=paths, ssgml_house=ssgml_house)
end

function run(::Val{Step2}; paths::SSGMLPaths, ssgml_house::SSGMLHouse)::Bool
    xmls_out = paths.xmls
    sgmls = readdir(paths.sgmls, join=true)
    if length(readdir(xmls_out)) == length(sgmls)
        @info "Step 2 already completed as $(xmls_out) exists and is populated, skipping..."
    else
        @info "Running step 2: Converting $(length(readlines(joinpath(dirname(@__FILE__), SGMLLinks))) - 1) sgm files to xml files..."
        @showprogress for year in sgmls
            for sgml in readdir(year, join=true)
                out = joinpath(xmls_out, split(split(sgml, basename(paths.sgmls))[end][2:end], ".")[1] * ".xml")
                mkpath(dirname(out))
                if isfile(out)
                    continue
                end
                sgml2xml(sgml, out)
            end
        end
    end
    return true
end

function run(::Val{Step3}; paths::SSGMLPaths, should_compress::Bool)::Bool
    @info "Running step 3: Cleaning and compressing files..."
    if should_compress
        compress(paths.base, paths.base * ".tar.zst", clear=true)
    end
    return true
end

export main
function (@main)(_ARGS)
    return run(; get_args()...) ? 0 : 1
end

end
