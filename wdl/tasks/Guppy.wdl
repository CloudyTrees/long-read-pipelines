version 1.0

##########################################################################################
# A workflow that runs the Guppy basecaller on ONT FAST5 files.
# - The docker tag number will match the version of Guppy that is being run. You can change
#   this value to run a different version of Guppy. Currently supports... [3.5.2, 3.6.0, 4.0.14]
# - All fast5 files within the given GCS dir, gcs_fast5_dir, will be processed
# - Takes a few hours to process 130GB. Best guess is that the processing time scales
#   linearly but untested.
##########################################################################################

import "Utils.wdl" as Utils
import "ONTUtils.wdl" as ONT
import "Structs.wdl"

workflow Guppy {
    input {
        String gcs_fast5_dir

        Int num_shards = 4
        String config
        Array[String] barcode_kits = []

        String instrument = "unknown"
        String flow_cell_id = "unknown"
        String? sample_id
        String? protocol_run_id

        String gcs_out_root_dir
    }

    call ListFast5s { input: gcs_fast5_dir = gcs_fast5_dir }
    call ONT.PartitionManifest as PartitionFast5Manifest { input: manifest = ListFast5s.manifest, N = num_shards }

    scatter (chunk_index in range(length(PartitionFast5Manifest.manifest_chunks))) {
        call Basecall {
            input:
                fast5_files  = read_lines(PartitionFast5Manifest.manifest_chunks[chunk_index]),
                config       = config,
                barcode_kits = barcode_kits,
                index        = chunk_index
        }
    }

    call Utils.Timestamp as TimestampStopped { input: dummy_dependencies = Basecall.sequencing_summary }

    call MakeSequencingSummary { input: sequencing_summaries = Basecall.sequencing_summary }

    call MakeFinalSummary {
        input:
            instrument      = instrument,
            flow_cell_id    = flow_cell_id,
            sample_id       = select_first([sample_id, Basecall.metadata[0]['sampleid']]),
            protocol_run_id = select_first([protocol_run_id, Basecall.metadata[0]['runid']]),
            started         = Basecall.metadata[0]['start_time'],
            stopped         = TimestampStopped.timestamp
    }

    call Utils.Uniq as UniqueBarcodes { input: strings = flatten(Basecall.barcodes) }

    call FinalizeBasecalls {
        input:
            pass_fastqs        = flatten(Basecall.pass_fastqs),
            fail_fastqs        = flatten(Basecall.fail_fastqs),
            sequencing_summary = MakeSequencingSummary.sequencing_summary,
            final_summary      = MakeFinalSummary.final_summary,
            barcodes           = UniqueBarcodes.unique_strings,
            outdir             = gcs_out_root_dir
    }

    output {
        String gcs_dir = FinalizeBasecalls.gcs_dir
        Array[File] sequencing_summaries = FinalizeBasecalls.sequencing_summaries
        Array[File] final_summaries = FinalizeBasecalls.final_summaries
        Array[String] barcodes = UniqueBarcodes.unique_strings
    }
}

task ListFast5s {
    input {
        String gcs_fast5_dir

        RuntimeAttr? runtime_attr_override
    }

    String indir = sub(gcs_fast5_dir, "/$", "")

    command <<<
        gsutil ls "~{indir}/**.fast5" > fast5_files.txt
    >>>

    output {
        File manifest = "fast5_files.txt"
    }

    #########################
    RuntimeAttr default_attr = object {
        cpu_cores:          1,
        mem_gb:             1,
        disk_gb:            1,
        boot_disk_gb:       10,
        preemptible_tries:  0,
        max_retries:        0,
        docker:             "us.gcr.io/broad-dsp-lrma/lr-utils:0.1.7"
    }
    RuntimeAttr runtime_attr = select_first([runtime_attr_override, default_attr])
    runtime {
        cpu:                    select_first([runtime_attr.cpu_cores,         default_attr.cpu_cores])
        memory:                 select_first([runtime_attr.mem_gb,            default_attr.mem_gb]) + " GiB"
        disks: "local-disk " +  select_first([runtime_attr.disk_gb,           default_attr.disk_gb]) + " HDD"
        bootDiskSizeGb:         select_first([runtime_attr.boot_disk_gb,      default_attr.boot_disk_gb])
        preemptible:            select_first([runtime_attr.preemptible_tries, default_attr.preemptible_tries])
        maxRetries:             select_first([runtime_attr.max_retries,       default_attr.max_retries])
        docker:                 select_first([runtime_attr.docker,            default_attr.docker])
    }
}

task MergeFastq {
    input {
        Array[File] guppy_output_files

        RuntimeAttr? runtime_attr_override
    }

    Int disk_size = 3 * ceil(size(guppy_output_files, "GB"))

    command <<<
        mkdir tmp
        mv -t tmp ~{sep=' ' guppy_output_files}

        cat tmp/*.fastq.gz > merged.fastq.gz
    >>>

    output {
        File merged_fastq = "merged.fastq.gz"
    }

    #########################
    RuntimeAttr default_attr = object {
        cpu_cores:          1,
        mem_gb:             1,
        disk_gb:            disk_size,
        boot_disk_gb:       10,
        preemptible_tries:  0,
        max_retries:        0,
        docker:             "us.gcr.io/broad-dsp-lrma/lr-utils:0.1.7"
    }
    RuntimeAttr runtime_attr = select_first([runtime_attr_override, default_attr])
    runtime {
        cpu:                    select_first([runtime_attr.cpu_cores,         default_attr.cpu_cores])
        memory:                 select_first([runtime_attr.mem_gb,            default_attr.mem_gb]) + " GiB"
        disks: "local-disk " +  select_first([runtime_attr.disk_gb,           default_attr.disk_gb]) + " HDD"
        bootDiskSizeGb:         select_first([runtime_attr.boot_disk_gb,      default_attr.boot_disk_gb])
        preemptible:            select_first([runtime_attr.preemptible_tries, default_attr.preemptible_tries])
        maxRetries:             select_first([runtime_attr.max_retries,       default_attr.max_retries])
        docker:                 select_first([runtime_attr.docker,            default_attr.docker])
    }
}

task Basecall {
    input {
        Array[File] fast5_files
        String config = "dna_r9.4.1_450bps_hac_prom.cfg"
        Array[String] barcode_kits = []
        Int index = 0

        RuntimeAttr? runtime_attr_override
    }

    Int disk_size = 3 * ceil(size(fast5_files, "GB"))

    String barcode_arg = if length(barcode_kits) > 0 then "--barcode_kits \"~{barcode_kits[0]}\" --trim_barcodes" else ""

    command <<<
        set -euxo pipefail

        guppy_basecaller \
            -r \
            -i /cromwell_root/ \
            -s guppy_output/ \
            -x "cuda:all" \
            -c ~{config} \
            ~{barcode_arg} \
            --compress_fastq

        find guppy_output/ -name '*fastq*' -not -path '*fail*' -type f | \
            awk -F"/" '{ a=NF-1; a=$a; gsub(/pass/, "unclassified", a); print a }' | \
            sort -n | \
            uniq > barcodes.txt

        mkdir pass
        find guppy_output/ -name '*fastq*' -not -path '*fail*' -type f | \
            awk -F"/" '{ a=NF-1; a=$a; b=$NF; gsub(/pass/, "unclassified", a); c=$NF; for (i = NF-1; i > 0; i--) { c=$i"/"c }; system("mv " c " pass/" a ".chunk_~{index}." b); }'

        mkdir fail
        find guppy_output/ -name '*fastq*' -not -path '*pass*' -type f | \
            awk -F"/" '{ a=NF-1; a=$a; b=$NF; gsub(/pass/, "unclassified", a); c=$NF; for (i = NF-1; i > 0; i--) { c=$i"/"c }; system("mv " c " fail/" a ".chunk_~{index}." b); }'

        find pass -name '*fastq.gz' -exec zcat {} \; | \
            head -1 2>/dev/null | \
            sed 's/ /\n/g' | \
            grep -v '^@' | \
            sed 's/=/\t/g' > metadata.txt
    >>>

    output {
        Array[File] pass_fastqs = glob("pass/*.fastq.gz")
        Array[File] fail_fastqs = glob("fail/*.fastq.gz")
        File sequencing_summary = "guppy_output/sequencing_summary.txt"
        Array[String] barcodes = read_lines("barcodes.txt")
        Map[String, String] metadata = read_map("metadata.txt")
    }

    #########################
    RuntimeAttr default_attr = object {
        cpu_cores:          4,
        mem_gb:             8,
        disk_gb:            disk_size,
        boot_disk_gb:       30,
        preemptible_tries:  0,
        max_retries:        0,
        docker:             "us.gcr.io/broad-dsp-lrma/lr-guppy:4.5.2"
    }
    RuntimeAttr runtime_attr = select_first([runtime_attr_override, default_attr])
    runtime {
        cpu:                    select_first([runtime_attr.cpu_cores,         default_attr.cpu_cores])
        memory:                 select_first([runtime_attr.mem_gb,            default_attr.mem_gb]) + " GiB"
        disks: "local-disk " +  select_first([runtime_attr.disk_gb,           default_attr.disk_gb]) + " HDD"
        bootDiskSizeGb:         select_first([runtime_attr.boot_disk_gb,      default_attr.boot_disk_gb])
        preemptible:            select_first([runtime_attr.preemptible_tries, default_attr.preemptible_tries])
        maxRetries:             select_first([runtime_attr.max_retries,       default_attr.max_retries])
        docker:                 select_first([runtime_attr.docker,            default_attr.docker])
        gpuType:                "nvidia-tesla-p100"
        gpuCount:               1
        nvidiaDriverVersion:    "418.152.00"
        zones:                  ["us-central1-c", "us-central1-f", "us-east1-b", "us-east1-c", "us-west1-a", "us-west1-b"]
        cpuPlatform:            "Intel Haswell"
    }
}

task MakeSequencingSummary {
    input {
        Array[File] sequencing_summaries

        RuntimeAttr? runtime_attr_override
    }

    Int disk_size = 3*ceil(size(sequencing_summaries, "GB"))

    command <<<
        set -euxo pipefail

        head -1 ~{sequencing_summaries[0]} > sequencing_summary.txt

        while read p; do
            awk 'NR > 1 { print }' "$p" >> sequencing_summary.txt
        done <~{write_lines(sequencing_summaries)}
    >>>

    output {
        File sequencing_summary = "sequencing_summary.txt"
    }

    #########################
    RuntimeAttr default_attr = object {
        cpu_cores:          1,
        mem_gb:             1,
        disk_gb:            disk_size,
        boot_disk_gb:       10,
        preemptible_tries:  0,
        max_retries:        0,
        docker:             "us.gcr.io/broad-dsp-lrma/lr-utils:0.1.7"
    }
    RuntimeAttr runtime_attr = select_first([runtime_attr_override, default_attr])
    runtime {
        cpu:                    select_first([runtime_attr.cpu_cores,         default_attr.cpu_cores])
        memory:                 select_first([runtime_attr.mem_gb,            default_attr.mem_gb]) + " GiB"
        disks: "local-disk " +  select_first([runtime_attr.disk_gb,           default_attr.disk_gb]) + " HDD"
        bootDiskSizeGb:         select_first([runtime_attr.boot_disk_gb,      default_attr.boot_disk_gb])
        preemptible:            select_first([runtime_attr.preemptible_tries, default_attr.preemptible_tries])
        maxRetries:             select_first([runtime_attr.max_retries,       default_attr.max_retries])
        docker:                 select_first([runtime_attr.docker,            default_attr.docker])
    }
}

task MakeFinalSummary {
    input {
        String instrument
        String sample_id
        String flow_cell_id
        String protocol_run_id
        String started
        String stopped

        RuntimeAttr? runtime_attr_override
    }

    Int disk_size = 1

    command <<<
        set -euxo pipefail

        echo 'instrument=~{instrument}' > final_summary.txt
        echo 'flow_cell_id=~{flow_cell_id}' >> final_summary.txt
        echo 'sample_id=~{sample_id}' >> final_summary.txt
        echo 'started=~{started}' >> final_summary.txt
        echo 'acquisition_stopped=~{stopped}' >> final_summary.txt
        echo 'processing_stopped=~{stopped}' >> final_summary.txt
        echo 'basecalling_enabled=1' >> final_summary.txt
        echo 'sequencing_summary_file=sequencing_summary.txt' >> final_summary.txt
    >>>

    output {
        File final_summary = "final_summary.txt"
    }

    #########################
    RuntimeAttr default_attr = object {
        cpu_cores:          1,
        mem_gb:             1,
        disk_gb:            disk_size,
        boot_disk_gb:       10,
        preemptible_tries:  0,
        max_retries:        0,
        docker:             "us.gcr.io/broad-dsp-lrma/lr-utils:0.1.7"
    }
    RuntimeAttr runtime_attr = select_first([runtime_attr_override, default_attr])
    runtime {
        cpu:                    select_first([runtime_attr.cpu_cores,         default_attr.cpu_cores])
        memory:                 select_first([runtime_attr.mem_gb,            default_attr.mem_gb]) + " GiB"
        disks: "local-disk " +  select_first([runtime_attr.disk_gb,           default_attr.disk_gb]) + " HDD"
        bootDiskSizeGb:         select_first([runtime_attr.boot_disk_gb,      default_attr.boot_disk_gb])
        preemptible:            select_first([runtime_attr.preemptible_tries, default_attr.preemptible_tries])
        maxRetries:             select_first([runtime_attr.max_retries,       default_attr.max_retries])
        docker:                 select_first([runtime_attr.docker,            default_attr.docker])
    }
}

task FinalizeBasecalls {
    input {
        Array[String] pass_fastqs
        Array[String] fail_fastqs
        File sequencing_summary
        File final_summary
        Array[String] barcodes

        String outdir

        RuntimeAttr? runtime_attr_override
    }

    String gcs_output_dir = sub(outdir + "/", "/+$", "")

    command <<<
        set -x

        PASS_FASTQ="~{write_lines(pass_fastqs)}"
        FAIL_FASTQ="~{write_lines(fail_fastqs)}"

        while read b; do
            OUT_DIR="~{gcs_output_dir}/$b"
            PASS_DIR="$OUT_DIR/fastq_pass/"
            FAIL_DIR="$OUT_DIR/fastq_fail/"

            grep -w $b $PASS_FASTQ | gsutil -m cp -I $PASS_DIR
            grep -w $b $FAIL_FASTQ | gsutil -m cp -I $FAIL_DIR

            if [ ~{length(barcodes)} -eq 1 ]; then
                cp ~{sequencing_summary} sequencing_summary.$b.txt
                cp ~{final_summary} final_summary.$b.txt
            else
                grep -e filename -e "$b[[:space:]]\+" ~{sequencing_summary} > sequencing_summary.$b.txt
                sed "s/sample_id=/sample_id=$b./" ~{final_summary} > final_summary.$b.txt
            fi

            gsutil cp sequencing_summary.$b.txt $OUT_DIR/
            gsutil cp final_summary.$b.txt $OUT_DIR/
        done <~{write_lines(barcodes)}
    >>>

    output {
        String gcs_dir = gcs_output_dir
        Array[File] sequencing_summaries = glob("sequencing_summary.*.txt")
        Array[File] final_summaries = glob("final_summary.*.txt")
    }

    #########################
    RuntimeAttr default_attr = object {
        cpu_cores:          1,
        mem_gb:             2,
        disk_gb:            10,
        boot_disk_gb:       10,
        preemptible_tries:  0,
        max_retries:        0,
        docker:             "us.gcr.io/broad-dsp-lrma/lr-finalize:0.1.2"
    }
    RuntimeAttr runtime_attr = select_first([runtime_attr_override, default_attr])
    runtime {
        cpu:                    select_first([runtime_attr.cpu_cores,         default_attr.cpu_cores])
        memory:                 select_first([runtime_attr.mem_gb,            default_attr.mem_gb]) + " GiB"
        disks: "local-disk " +  select_first([runtime_attr.disk_gb,           default_attr.disk_gb]) + " HDD"
        bootDiskSizeGb:         select_first([runtime_attr.boot_disk_gb,      default_attr.boot_disk_gb])
        preemptible:            select_first([runtime_attr.preemptible_tries, default_attr.preemptible_tries])
        maxRetries:             select_first([runtime_attr.max_retries,       default_attr.max_retries])
        docker:                 select_first([runtime_attr.docker,            default_attr.docker])
    }
}