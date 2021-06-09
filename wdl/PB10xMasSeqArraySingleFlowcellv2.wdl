version 1.0

import "tasks/PBUtils.wdl" as PB
import "tasks/Utils.wdl" as Utils
import "tasks/Finalize.wdl" as FF
import "tasks/AlignReads.wdl" as AR
import "tasks/Cartographer.wdl" as CART
import "tasks/TranscriptAnalysis/Flair_Tasks.wdl" as ISO
import "tasks/ReadsMetrics.wdl" as RM
import "tasks/AlignedMetrics.wdl" as AM
import "tasks/Ten_X_Tool.wdl" as TENX
import "tasks/JupyterNotebooks.wdl" as JUPYTER
import "tasks/Longbow.wdl" as LONGBOW

import "tasks/TranscriptAnalysis/UMI_Tools.wdl" as UMI_TOOLS
import "tasks/TranscriptAnalysis/Postprocessing_Tasks.wdl" as TX_POST

workflow PB10xMasSeqSingleFlowcellv2 {

    meta {
        description : "This workflow is designed to process data from the MASSeq v2 protocol and produce aligned reads that are ready for downstream analysis (e.g. transcript isoform identification).  It takes in a raw PacBio run folder location on GCS and produces a folder containing the aligned reads and other processed data."
        author : "Jonn Smith"
        email : "jonn@broadinstitute.org"
    }

    input {
        String gcs_input_dir
        String gcs_out_root_dir = "gs://broad-dsde-methods-long-reads-outgoing/PB10xMasSeqSingleFlowcellv2"

        File segments_fasta = "gs://broad-dsde-methods-long-reads/resources/MASseq_0.0.2/cDNA_array_15x.unique_seqs_for_cartographer.fasta"
        File boundaries_file = "gs://broad-dsde-methods-long-reads/resources/MASseq_0.0.2/bounds_file_for_extraction.txt"

        File head_adapter_fasta = "gs://broad-dsde-methods-long-reads/resources/MASseq_0.0.2/10x_adapter.fasta"
        File tail_adapter_fasta = "gs://broad-dsde-methods-long-reads/resources/MASseq_0.0.2/tso_adapter.fasta"
        File ten_x_cell_barcode_whitelist = "gs://broad-dsde-methods-long-reads/resources/MASseq_0.0.2/10x_Barcodes_3M-february-2018.txt"

        # NOTE: Reference for un-split CCS reads:
        File ref_fasta =  "gs://broad-dsde-methods-long-reads/resources/references/grch38/Homo_sapiens_assembly38.fasta"
        File ref_fasta_index = "gs://broad-dsde-methods-long-reads/resources/references/grch38/Homo_sapiens_assembly38.fasta.fai"
        File ref_fasta_dict = "gs://broad-dsde-methods-long-reads/resources/references/grch38/Homo_sapiens_assembly38.dict"

        # NOTE: Reference for array elements:
        File transcriptome_ref_fasta =  "gs://broad-dsde-methods-long-reads/resources/gencode_v37/gencode.v37.pc_transcripts.fa"
        File transcriptome_ref_fasta_index = "gs://broad-dsde-methods-long-reads/resources/gencode_v37/gencode.v37.pc_transcripts.fa.fai"
        File transcriptome_ref_fasta_dict = "gs://broad-dsde-methods-long-reads/resources/gencode_v37/gencode.v37.pc_transcripts.dict"

        File genome_annotation_gtf = "gs://broad-dsde-methods-long-reads/resources/gencode_v37/gencode.v37.primary_assembly.annotation.gtf"

        File jupyter_template_static = "gs://broad-dsde-methods-long-reads/resources/MASseq_0.0.2/MAS-seq_QC_report_template-static.ipynb"
        File workflow_dot_file = "gs://broad-dsde-methods-long-reads/resources/MASseq_0.0.2/PB10xMasSeqArraySingleFlowcellv2.dot"

        File? illumina_barcoded_bam

        # Default here is 0 because ccs uncorrected reads all seem to have RQ = -1.
        # All pathologically long reads also have RQ = -1.
        # This way we preserve the vast majority of the data, even if it has low quality.
        # We can filter it out at later steps.
        Float min_read_quality = 0.0
        Int max_reclamation_length = 60000

        Boolean is_SIRV_data = false
        String mas_seq_model = "mas15"

        String? sample_name
    }

    parameter_meta {
        gcs_input_dir : "Input folder on GCS in which to search for BAM files to process."
        gcs_out_root_dir : "Root output GCS folder in which to place results of this workflow."

        segments_fasta : "FASTA file containing unique segments for which to search in the given BAM files.   These segments are used as delimiters in the reads.  Read splitting uses these delimiters and the boundaries file."
        boundaries_file : "Text file containing two comma-separated segment names from the segments_fasta on each line.  These entries define delimited sections to be extracted from the reads and treated as individual array elements."

        head_adapter_fasta : "FASTA file containing the sequence that each transcript should start with.  Typically this will be the 10x adapter sequence from the 10x library prep."
        tail_adapter_fasta : "FASTA file containing the sequence that each transcript should end with.  Typically this will be the Template Switch Oligo (TSO) sequence from the 10x library prep."
        ten_x_cell_barcode_whitelist : "Text file containing a whitelist of cell barcodes for the 10x library prep."

        ref_fasta : "FASTA file containing the reference sequence to which the input data should be aligned before splitting into array elements."
        ref_fasta_index : "FASTA index file for the given ref_fasta file."
        ref_fasta_dict : "Sequence dictionary file for the given ref_fasta file."

        transcriptome_ref_fasta : "FASTA file containing the reference sequence to which the array elements should be aligned."
        transcriptome_ref_fasta_index : "FASTA index file for the given transcriptome_ref_fasta file."
        transcriptome_ref_fasta_dict : "Sequence dictionary file for the given transcriptome_ref_fasta file."

        genome_annotation_gtf : "Gencode GTF file containing genome annotations for the organism under study (usually humans).  This must match the given reference version (usually hg38)."

        jupyter_template_static : "Jupyter notebook / ipynb file containing a template for the QC report which will contain static plots.  This should contain the same information as the jupyter_template_interactive file, but with static images."
        workflow_dot_file : "DOT file containing the representation of this WDL to be included in the QC reports.  This can be generated with womtool."

        illumina_barcoded_bam : "[optional] Illumina short reads file from a replicate of this same sample.  Used to perform cell barcode corrections."

        min_read_quality : "[optional] Minimum read quality for reads to have to be included in our data (Default: 0.0)."
        max_reclamation_length : "[optional] Maximum length (in bases) that a read can be to attempt to reclaim from CCS rejection (Default: 60000)."

        is_SIRV_data : "[optional] true if and only if the data in this sample are from the SIRV library prep.  false otherwise (Default: false)"
        mas_seq_model : "[optional] built-in mas-seq model to use (Default: mas15)"

        sample_name : "[optional] The name of the sample to associate with the data in this workflow."
    }

    # Call our timestamp so we can store outputs without clobbering previous runs:
    call Utils.GetCurrentTimestampString as WdlExecutionStartTimestamp { input: }

    String outdir = sub(gcs_out_root_dir, "/$", "")

    call PB.FindBams { input: gcs_input_dir = gcs_input_dir }
    call PB.FindZmwStatsJsonGz { input: gcs_input_dir = gcs_input_dir }

    # Check here if we found ccs bams or subread bams:
    Boolean use_subreads = FindBams.has_subreads
    Array[String] top_level_bam_files = if use_subreads then FindBams.subread_bams else FindBams.ccs_bams

    # Make sure we have **EXACTLY** one bam file to run on:
    if (length(top_level_bam_files) != 1) {
        call Utils.FailWithWarning as WARN1 { input: warning = "Error: Multiple BAM files found.  Cannot continue!" }
    }

    if (use_subreads) {
        call Utils.FailWithWarning as WARN2 { input: warning = "Error: This workflow now only supports data from the Sequel IIe." }
    }

    # Alias our bam file so we can work with it easier:
    File reads_bam = top_level_bam_files[0]

    call PB.GetRunInfo { input: subread_bam = reads_bam }

    String SM  = select_first([sample_name, GetRunInfo.run_info["SM"]])
    String PL  = "PACBIO"
    String PU  = GetRunInfo.run_info["PU"]
    String DT  = GetRunInfo.run_info["DT"]
    String ID  = PU
    String DS  = GetRunInfo.run_info["DS"]
    String DIR = SM + "." + ID

    String RG_subreads  = "@RG\\tID:~{ID}.subreads\\tSM:~{SM}\\tPL:~{PL}\\tPU:~{PU}\\tDT:~{DT}"
    String RG_consensus = "@RG\\tID:~{ID}.consensus\\tSM:~{SM}\\tPL:~{PL}\\tPU:~{PU}\\tDT:~{DT}"
    String RG_array_elements = "@RG\\tID:~{ID}.array_elements\\tSM:~{SM}\\tPL:~{PL}\\tPU:~{PU}\\tDT:~{DT}"

    # Check to see if we need to annotate our reads:
    call LONGBOW.CheckForAnnotatedArrayReads {
        input:
            bam = reads_bam
    }

    File read_pbi = sub(reads_bam, ".bam$", ".bam.pbi")
    call PB.ShardLongReads {
        input:
            unaligned_bam = reads_bam,
            unaligned_pbi = read_pbi,
            prefix = SM + "_shard",
            num_shards = 50,
    }

    scatter (sharded_reads in ShardLongReads.unmapped_shards) {

        ## No more preemption on this sharding - takes too long otherwise.
        RuntimeAttr disable_preemption_runtime_attrs = object {
            preemptible_tries: 0
        }

        String fbmrq_prefix = basename(sharded_reads, ".bam")

        # Filter out the kinetics tags from PB files:
        call PB.RemoveKineticsTags {
            input:
                bam = sharded_reads,
                prefix = SM + "_kinetics_removed"
        }

        # Handle setting up the things that we need for further processing of CCS-only reads:
        call PB.FindCCSReport {
            input:
                gcs_input_dir = gcs_input_dir
        }

        # 1 - filter the reads by the minimum read quality:
        call Utils.Bamtools as FilterS2EByMinReadQuality {
            input:
                bamfile = RemoveKineticsTags.bam_file,
                prefix = fbmrq_prefix + "_good_reads",
                cmd = "filter",
                args = '-tag "rq":">=' + min_read_quality + '"',
                runtime_attr_override = disable_preemption_runtime_attrs
        }

        # 1.5 - Get the "rejected" reads:
        call Utils.Bamtools as GetS2ERCcsRejectedReads {
            input:
                bamfile = RemoveKineticsTags.bam_file,
                prefix = fbmrq_prefix + "_rejected_reads",
                cmd = "filter",
                args = '-tag "rq":"<' + min_read_quality + '"',
                runtime_attr_override = disable_preemption_runtime_attrs
        }

        # 2 - Get reads we can reclaim:
        call Utils.Bamtools as ExtractS2ECcsReclaimableReads {
            input:
                bamfile = RemoveKineticsTags.bam_file,
                prefix = fbmrq_prefix + "_reads_for_ccs_reclamation",
                cmd = "filter",
                args = '-tag "rq":"<' + min_read_quality + '" -length "<=' + max_reclamation_length + '"',
                runtime_attr_override = disable_preemption_runtime_attrs
        }

        if ( ! CheckForAnnotatedArrayReads.bam_has_annotations ) {
            # 3: Longbow annotate ccs reads
            call LONGBOW.Annotate as AnnotateS2ECCSReads {
                input:
                    reads = FilterS2EByMinReadQuality.bam_out,
                    model = mas_seq_model
            }
            # 4: Longbow annotate reclaimable reads
            call LONGBOW.Annotate as AnnotateS2EReclaimableReads {
                input:
                    reads = ExtractS2ECcsReclaimableReads.bam_out,
                    model = mas_seq_model
            }
        }

        File annotated_S2E_ccs_file = if CheckForAnnotatedArrayReads.bam_has_annotations then FilterS2EByMinReadQuality.bam_out else select_first([AnnotateS2ECCSReads.annotated_bam])
        File annotated_S2E_reclaimable_file = if CheckForAnnotatedArrayReads.bam_has_annotations then ExtractS2ECcsReclaimableReads.bam_out else select_first([AnnotateS2EReclaimableReads.annotated_bam])

        # 5: Longbow filter ccs annotated reads
        call LONGBOW.Filter as FilterS2ECCSReads {
            input:
                bam = annotated_S2E_ccs_file,
                prefix = SM + "_subshard",
                model = mas_seq_model
        }

        # 6: Longbow filter ccs reclaimable reads
        call LONGBOW.Filter as FilterS2EReclaimableReads {
            input:
                bam = annotated_S2E_reclaimable_file,
                prefix = SM + "_subshard",
                model = mas_seq_model
        }

        # 7: Merge reclaimed and ccs longbow filtered reads
        call Utils.MergeBams as MergeLongbowS2EPassedReads {
            input:
                bams = [FilterS2ECCSReads.passed_reads, FilterS2EReclaimableReads.passed_reads],
                prefix = SM + "_LongbowFilter_Failed_1"
        }
        call Utils.MergeBams as MergeLongbowS2EFailedReads {
            input:
                bams = [FilterS2ECCSReads.failed_reads, FilterS2EReclaimableReads.failed_reads],
                prefix = SM + "_LongbowFilter_Failed_1"
        }

        # 8: PBIndex reads
        call PB.PBIndex as PbIndexS2ELongbowPassedReads {
            input:
                bam = MergeLongbowS2EPassedReads.merged_bam
        }

        # 9: Get CCS Reclaimed array elements for further study:
        call PB.PBIndex as PbIndexS2ECcsReclaimedReads {
            input:
                bam = FilterS2EReclaimableReads.passed_reads
        }
        call PB.ShardLongReads as ShardS2ECcsReclaimedReads {
            input:
                unaligned_bam = FilterS2EReclaimableReads.passed_reads,
                unaligned_pbi = PbIndexS2ECcsReclaimedReads.pbindex,
                prefix = SM + "_ccs_reclaimed_reads_subshard",
                num_shards = 10,
        }
        scatter (s2e_ccs_reclaimed_shard in ShardS2ECcsReclaimedReads.unmapped_shards) {
            call LONGBOW.Segment as SegmentS2ECcsReclaimedReads {
                input:
                    annotated_reads = s2e_ccs_reclaimed_shard,
                    prefix = SM + "_ccs_reclaimed_array_elements_subshard",
                    model = mas_seq_model
            }
        }
        call Utils.MergeBams as MergeS2ECcsReclaimedArrayElementSubshards {
        input:
            bams = SegmentS2ECcsReclaimedReads.segmented_bam,
            prefix = SM + "_ccs_reclaimed_array_elements_shard"
        }


        # Shard these reads even wider so we can make sure we don't run out of memory:
        call PB.ShardLongReads as ShardCorrectedReads {
            input:
                unaligned_bam = MergeLongbowS2EPassedReads.merged_bam,
                unaligned_pbi = PbIndexS2ELongbowPassedReads.pbindex,
                prefix = SM + "_longbow_all_passed_subshard",
                num_shards = 10,
        }

        # Segment our arrays into individual array elements:
        scatter (corrected_shard in ShardCorrectedReads.unmapped_shards) {
            call LONGBOW.Segment as SegmentAnnotatedReads {
                input:
                    annotated_reads = corrected_shard,
                    model = mas_seq_model
            }
        }

        # Merge all outputs of Longbow Annotate / Segment:
        call Utils.MergeBams as MergeArrayElements_1 {
            input:
                bams = SegmentAnnotatedReads.segmented_bam,
                prefix = SM + "_ArrayElements_intermediate_1"
        }

        # The SIRV library prep is slightly different from the standard prep, so we have to account for it here:
        if (is_SIRV_data) {
            call TENX.TagSirvUmiPositionsFromLongbowAnnotatedArrayElement {
                input:
                    bam_file = MergeArrayElements_1.merged_bam,
                    prefix = SM + "_ArrayElements_SIRV_UMI_Extracted"
            }
        }
        if ( ! is_SIRV_data ) {

            RuntimeAttr tenx_annotation_attrs = object {
                mem_gb: 32
            }

            call TENX.AnnotateBarcodesAndUMIs as TenxAnnotateArrayElements {
                input:
                    bam_file = MergeArrayElements_1.merged_bam,
                    bam_index = MergeArrayElements_1.merged_bai,
                    head_adapter_fasta = head_adapter_fasta,
                    tail_adapter_fasta = tail_adapter_fasta,
                    whitelist_10x = ten_x_cell_barcode_whitelist,
                    illumina_barcoded_bam = illumina_barcoded_bam,
                    read_end_length = 200,
                    poly_t_length = 31,
                    barcode_length = 16,
                    umi_length = 10,
                    runtime_attr_override = tenx_annotation_attrs
            }
        }

        # Create an alias here that we can refer to in later steps regardless as to whether we have SIRV data or not
        # This `select_first` business is some sillyness to fix the conditional calls automatically converting the
        # output to `File?` instead of `File`
        File annotated_array_elements = if is_SIRV_data then select_first([TagSirvUmiPositionsFromLongbowAnnotatedArrayElement.output_bam]) else select_first([TenxAnnotateArrayElements.output_bam])

        # Grab only the coding regions of the annotated reads for our alignments:
        Int extract_start_offset = if is_SIRV_data then 8 else 26
        call LONGBOW.Extract as ExtractCodingRegionsFromArrayElements {
            input:
                bam = annotated_array_elements,
                start_offset = extract_start_offset,
                prefix = SM + "_ArrayElements_Coding_Regions_Only"
        }

        # Align our array elements:
        call AR.Minimap2 as AlignArrayElements {
            input:
                reads      = [ ExtractCodingRegionsFromArrayElements.extracted_reads ],
                ref_fasta  = transcriptome_ref_fasta,
                map_preset = "splice:hq"
        }

        call AR.Minimap2 as AlignArrayElementsToGenome {
            input:
                reads      = [ ExtractCodingRegionsFromArrayElements.extracted_reads ],
                ref_fasta  = ref_fasta,
                map_preset = "splice:hq"
        }

        # We need to restore the annotations we created with the 10x tool to the aligned reads.
        call TENX.RestoreAnnotationstoAlignedBam as RestoreAnnotationsToTranscriptomeAlignedBam {
            input:
                annotated_bam_file = ExtractCodingRegionsFromArrayElements.extracted_reads,
                aligned_bam_file = AlignArrayElements.aligned_bam,
                tags_to_ignore = [],
                mem_gb = 64,  # TODO: Debug for memory redution
        }

        # We need to restore the annotations we created with the 10x tool to the aligned reads.
        call TENX.RestoreAnnotationstoAlignedBam as RestoreAnnotationsToGenomeAlignedBam {
            input:
                annotated_bam_file = ExtractCodingRegionsFromArrayElements.extracted_reads,
                aligned_bam_file = AlignArrayElementsToGenome.aligned_bam,
                tags_to_ignore = [],
                mem_gb = 64,  # TODO: Debug for memory redution
        }

        # To properly count our transcripts we must throw away the non-primary and unaligned reads:
        RuntimeAttr filterReadsAttrs = object {
            cpu_cores: 4,
            preemptible_tries: 0
        }
        call Utils.FilterReadsBySamFlags as RemoveUnmappedAndNonPrimaryReads {
            input:
                bam = RestoreAnnotationsToTranscriptomeAlignedBam.output_bam,
                sam_flags = "2308",
                prefix = SM + "_ArrayElements_Annotated_Aligned_PrimaryOnly",
                runtime_attr_override = filterReadsAttrs
        }

        # Filter reads with no UMI tag:
        call Utils.FilterReadsWithTagValues as FilterReadsWithNoUMI {
            input:
                bam = RemoveUnmappedAndNonPrimaryReads.output_bam,
                tag = "ZU",
                value_to_remove = ".",
                prefix = SM + "_ArrayElements_Annotated_Aligned_PrimaryOnly_WithUMIs",
                runtime_attr_override = filterReadsAttrs
        }

        # Copy the contig to a tag.
        # By this point in the pipeline, array elements are aligned to a transcriptome, so this tag will
        # actually indicate the transcript to which each array element aligns.
        call TENX.CopyContigNameToReadTag {
            input:
                aligned_bam_file = FilterReadsWithNoUMI.output_bam,
                prefix = SM + "_ArrayElements_Annotated_Aligned_PrimaryOnly_WithUMIs"
        }
    }

    #################################################
    #   __  __
    #  |  \/  | ___ _ __ __ _  ___
    #  | |\/| |/ _ \ '__/ _` |/ _ \
    #  | |  | |  __/ | | (_| |  __/
    #  |_|  |_|\___|_|  \__, |\___|
    #                   |___/
    #
    # Merge all the sharded files we created above into files for this
    # input bam file.
    #################################################

    # Sequel IIe Data.
    # CCS Passed:
    call Utils.MergeBams as MergeCCSRqFilteredReads { input: bams = FilterS2EByMinReadQuality.bam_out, prefix = SM + "_ccs_reads" }
    call Utils.MergeBams as MergeCCSRqRejectedReads { input: bams = GetS2ERCcsRejectedReads.bam_out, prefix = SM + "_ccs_rejected_reads" }
    call Utils.MergeBams as MergeAnnotatedCCSReads_S2e { input: bams = annotated_S2E_ccs_file, prefix = SM + "_ccs_reads_annotated" }
    call Utils.MergeBams as MergeLongbowPassedCCSReads_S2e { input: bams = FilterS2ECCSReads.passed_reads, prefix = SM + "_ccs_reads_annotated_longbow_passed" }
    call Utils.MergeBams as MergeLongbowFailedCCSReads_S2e { input: bams = FilterS2ECCSReads.failed_reads, prefix = SM + "_ccs_reads_annotated_longbow_failed" }

    # CCS Failed / Reclaimable:
    call Utils.MergeBams as MergeCCSReclaimableReads_S2e { input: bams = ExtractS2ECcsReclaimableReads.bam_out, prefix = SM + "_ccs_rejected_reclaimable" }
    call Utils.MergeBams as MergeCCSReclaimableAnnotatedReads_S2e { input: bams = annotated_S2E_reclaimable_file, prefix = SM + "_ccs_rejected_reclaimable_annotated" }
    call Utils.MergeBams as MergeLongbowPassedReclaimable_S2e { input: bams = FilterS2EReclaimableReads.passed_reads, prefix = SM + "_ccs_rejected_reclaimable_annotated_longbow_passed" }
    call Utils.MergeBams as MergeLongbowFailedReclaimable_S2e { input: bams = FilterS2EReclaimableReads.failed_reads, prefix = SM + "_ccs_rejected_reclaimable_annotated_longbow_failed" }

    # All Longbow Passed / Failed reads:
    call Utils.MergeBams as MergeAllLongbowPassedReads_S2e { input: bams = MergeLongbowS2EPassedReads.merged_bam, prefix = SM + "_all_longbow_passed" }
    call Utils.MergeBams as MergeAllLongbowFailedReads_S2e { input: bams = MergeLongbowS2EFailedReads.merged_bam, prefix = SM + "_all_longbow_failed" }

    # Merge CCS Reclaimed Array elements:
    call Utils.MergeBams as MergeCCSReclaimedArrayElements_S2e { input: bams = MergeS2ECcsReclaimedArrayElementSubshards.merged_bam, prefix = SM + "_ccs_reclaimed_array_elements"  }


    # Alias out the data we need to pass into stuff later:
    File ccs_corrected_reads = MergeCCSRqFilteredReads.merged_bam
    File ccs_corrected_reads_index = MergeCCSRqFilteredReads.merged_bai
    File ccs_rejected_reads = MergeCCSRqRejectedReads.merged_bam
    File ccs_rejected_reads_index = MergeCCSRqRejectedReads.merged_bai
    File annotated_ccs_reads = MergeAnnotatedCCSReads_S2e.merged_bam
    File annotated_ccs_reads_index = MergeAnnotatedCCSReads_S2e.merged_bai
    File longbow_passed_ccs_reads = MergeLongbowPassedCCSReads_S2e.merged_bam
    File longbow_passed_ccs_reads_index = MergeLongbowPassedCCSReads_S2e.merged_bai
    File longbow_failed_ccs_reads = MergeLongbowFailedCCSReads_S2e.merged_bam
    File longbow_failed_ccs_reads_index = MergeLongbowFailedCCSReads_S2e.merged_bai
    File ccs_reclaimable_reads = MergeCCSReclaimableReads_S2e.merged_bam
    File ccs_reclaimable_reads_index = MergeCCSReclaimableReads_S2e.merged_bai
    
    File annotated_ccs_reclaimable_reads = MergeCCSReclaimableAnnotatedReads_S2e.merged_bam
    
    File annotated_ccs_reclaimable_reads_index = MergeCCSReclaimableAnnotatedReads_S2e.merged_bai
    File ccs_reclaimed_reads = MergeLongbowPassedReclaimable_S2e.merged_bam
    File ccs_reclaimed_reads_index = MergeLongbowPassedReclaimable_S2e.merged_bai
    File longbow_failed_ccs_unreclaimable_reads = MergeLongbowFailedReclaimable_S2e.merged_bam
    File longbow_failed_ccs_unreclaimable_reads_index = MergeLongbowFailedReclaimable_S2e.merged_bai
    File longbow_passed_reads = MergeAllLongbowPassedReads_S2e.merged_bam
    File longbow_passed_reads_index = MergeAllLongbowPassedReads_S2e.merged_bai
    File longbow_failed_reads = MergeAllLongbowFailedReads_S2e.merged_bam
    File longbow_failed_reads_index = MergeAllLongbowFailedReads_S2e.merged_bai

    File ccs_reclaimed_array_elements = MergeCCSReclaimedArrayElements_S2e.merged_bam
    File ccs_reclaimed_array_elements_index = MergeCCSReclaimedArrayElements_S2e.merged_bai

    # Merge all CCS bams together for this Subread BAM:
    RuntimeAttr merge_extra_cpu_attrs = object {
        cpu_cores: 4
    }
    call Utils.MergeBams as MergeCbcUmiArrayElements { input: bams = annotated_array_elements, prefix = SM + "_array_elements", runtime_attr_override = merge_extra_cpu_attrs }  # TODO: Make prefix: `_annotated_array_elements`
    call Utils.MergeBams as MergeLongbowExtractedArrayElements { input: bams = ExtractCodingRegionsFromArrayElements.extracted_reads, prefix = SM + "_array_elements_longbow_extracted" }
    call Utils.MergeBams as MergeTranscriptomeAlignedExtractedArrayElements { input: bams = RestoreAnnotationsToTranscriptomeAlignedBam.output_bam, prefix = SM + "_array_elements_longbow_extracted_tx_aligned", runtime_attr_override = merge_extra_cpu_attrs }
    call Utils.MergeBams as MergeGenomeAlignedExtractedArrayElements { input: bams = RestoreAnnotationsToGenomeAlignedBam.output_bam, prefix = SM + "_array_elements_longbow_extracted_genome_aligned", runtime_attr_override = merge_extra_cpu_attrs }
    call Utils.MergeBams as MergePrimaryTranscriptomeAlignedArrayElements { input: bams = CopyContigNameToReadTag.output_bam, prefix = SM + "_array_elements_longbow_extracted_tx_aligned_primary_alignments", runtime_attr_override = merge_extra_cpu_attrs }

    # NEW PB INDEXING IS BEING DIFFICULT.  REMOVED FOR NOW.
#    # PbIndex some key files:
#    call PB.PBIndex as PbIndexPrimaryTranscriptomeAlignedArrayElements {
#        input:
#            bam = MergePrimaryTranscriptomeAlignedArrayElements.merged_bam
#    }

    # Merge the 10x stats:
    if ( ! is_SIRV_data ) {
        call Utils.MergeCountTsvFiles as Merge10XStats_1 {
            input:
                count_tsv_files = select_all(TenxAnnotateArrayElements.stats),
                prefix = SM + "_10x_stats"
        }
    }

    # Collect metrics on the subreads bam:
    RuntimeAttr subreads_sam_stats_runtime_attrs = object {
        cpu_cores:          2,
        mem_gb:             8,
        disk_gb:            ceil(3 * size(reads_bam, "GiB")),
        boot_disk_gb:       10,
        preemptible_tries:  0,
        max_retries:        1,
        docker:             "us.gcr.io/broad-dsp-lrma/lr-metrics:0.1.8"
    }
    call AM.SamtoolsStats as CalcSamStatsOnInputBam {
        input:
            bam = reads_bam,
            runtime_attr_override = subreads_sam_stats_runtime_attrs
    }

    ##########
    # Quantify Transcripts:
    ##########

    call UMI_TOOLS.Run_Group as UMIToolsGroup {
        input:
            aligned_transcriptome_reads = MergePrimaryTranscriptomeAlignedArrayElements.merged_bam,
            aligned_transcriptome_reads_index = MergePrimaryTranscriptomeAlignedArrayElements.merged_bai,
            do_per_cell = !is_SIRV_data,
            prefix = "~{SM}_~{ID}_umi_tools_group"
    }

    call TX_POST.CreateCountMatrixFromAnnotatedBam {
        input:
            annotated_transcriptome_bam = UMIToolsGroup.output_bam,
            prefix = "~{SM}_~{ID}_gene_tx_expression_count_matrix"
    }

    # Only create the anndata objects if we're looking at real genomic data:
    if ( ! is_SIRV_data ) {
        call TX_POST.CreateCountMatrixAnndataFromTsv {
            input:
                count_matrix_tsv = CreateCountMatrixFromAnnotatedBam.count_matrix,
                gencode_gtf_file = genome_annotation_gtf,
                prefix = "~{SM}_~{ID}_gene_tx_expression_count_matrix"
        }
    }

    ############################################################
    #               __  __      _        _
    #              |  \/  | ___| |_ _ __(_) ___ ___
    #              | |\/| |/ _ \ __| '__| |/ __/ __|
    #              | |  | |  __/ |_| |  | | (__\__ \
    #              |_|  |_|\___|\__|_|  |_|\___|___/
    #
    ############################################################

    String base_out_dir = outdir + "/" + DIR + "/" + WdlExecutionStartTimestamp.timestamp_string
    String metrics_out_dir = base_out_dir + "/metrics"

    # Aligned CCS Metrics:
    call RM.CalculateAndFinalizeReadMetrics as GenomeAlignedArrayElementMetrics {
        input:
            bam_file = MergeGenomeAlignedExtractedArrayElements.merged_bam,
            bam_index = MergeGenomeAlignedExtractedArrayElements.merged_bai,
            ref_dict = ref_fasta_dict,

            base_metrics_out_dir = metrics_out_dir + "/genome_aligned_array_element_metrics"
    }

    # Aligned Array Element Metrics:
    call RM.CalculateAndFinalizeAlternateReadMetrics as TranscriptomeAlignedArrayElementMetrics {
        input:
            bam_file = MergeTranscriptomeAlignedExtractedArrayElements.merged_bam,
            bam_index = MergeTranscriptomeAlignedExtractedArrayElements.merged_bai,
            ref_dict = transcriptome_ref_fasta_dict,

            base_metrics_out_dir = metrics_out_dir + "/transcriptome_aligned_array_element_metrics"
    }

    # We should have exactly 1 CCS report for Sequel IIe reads:
    File final_ccs_report = FindCCSReport.ccs_report[0]

    ##########################################################################################
    #         ____                _                ____                       _
    #        / ___|_ __ ___  __ _| |_ ___         |  _ \ ___ _ __   ___  _ __| |_
    #       | |   | '__/ _ \/ _` | __/ _ \        | |_) / _ \ '_ \ / _ \| '__| __|
    #       | |___| | |  __/ (_| | ||  __/        |  _ <  __/ |_) | (_) | |  | |_
    #        \____|_|  \___|\__,_|\__\___|        |_| \_\___| .__/ \___/|_|   \__|
    #                                                       |_|
    ##########################################################################################

    RuntimeAttr create_report_runtime_attrs = object {
            preemptible_tries:  0
    }
    call JUPYTER.PB10xMasSeqSingleFlowcellReport as GenerateStaticReport {
        input:
            notebook_template                 = jupyter_template_static,

            sample_name                       = SM,

            subreads_stats                    = CalcSamStatsOnInputBam.raw_stats,
            ccs_reads_stats                   = GenomeAlignedArrayElementMetrics.sam_stats_raw_stats,
            array_elements_stats              = TranscriptomeAlignedArrayElementMetrics.sam_stats_raw_stats,
            ccs_report_file                   = final_ccs_report,

            raw_ccs_bam_file                  = ccs_corrected_reads,
            array_element_bam_file            = MergeTranscriptomeAlignedExtractedArrayElements.merged_bam,
            array_elements_genome_aligned     = MergeGenomeAlignedExtractedArrayElements.merged_bam,
            ccs_rejected_bam_file             = ccs_rejected_reads,

            annotated_bam_file                = annotated_ccs_reads,

            longbow_passed_reads_file         = longbow_passed_reads,
            longbow_failed_reads_file         = longbow_failed_reads,

            longbow_passed_ccs_reads          = longbow_passed_ccs_reads,
            longbow_failed_ccs_reads          = longbow_failed_ccs_reads,
            ccs_reclaimable_reads             = annotated_ccs_reclaimable_reads,
            ccs_reclaimed_reads               = ccs_reclaimed_reads,
            ccs_rejected_longbow_failed_reads = longbow_failed_ccs_unreclaimable_reads,
            raw_array_elements                = MergeCbcUmiArrayElements.merged_bam,
            ccs_reclaimed_array_elements      = ccs_reclaimed_array_elements,

            zmw_stats_json_gz                 = FindZmwStatsJsonGz.zmw_stats_json_gz,

            ten_x_metrics_file                = Merge10XStats_1.merged_tsv,
            mas_seq_model                     = mas_seq_model,

            workflow_dot_file                 = workflow_dot_file,
            prefix                            = SM + "_MAS-seq_",

            runtime_attr_override             = create_report_runtime_attrs,
    }

    ######################################################################
    #             _____ _             _ _
    #            |  ___(_)_ __   __ _| (_)_______
    #            | |_  | | '_ \ / _` | | |_  / _ \
    #            |  _| | | | | | (_| | | |/ /  __/
    #            |_|   |_|_| |_|\__,_|_|_/___\___|
    #
    ######################################################################

    # NOTE: We key all finalization steps on the static report.
    #       This will prevent incomplete runs from being placed in the output folders.

    String array_element_dir = base_out_dir + "/annotated_array_elements"
    String intermediate_reads_dir = base_out_dir + "/intermediate_reads"
    String quant_dir = base_out_dir + "/quant"
    String report_dir = base_out_dir + "/report"

    ##############################################################################################################
    # Finalize the final annotated, aligned array elements:
    call FF.FinalizeToDir as FinalizeQuantifiedArrayElements {
        input:
            files = [
                MergePrimaryTranscriptomeAlignedArrayElements.merged_bam,
                MergePrimaryTranscriptomeAlignedArrayElements.merged_bai,
#                PbIndexPrimaryTranscriptomeAlignedArrayElements.pbindex
            ],
            outdir = array_element_dir,
            keyfile = GenerateStaticReport.html_report
    }

    ##############################################################################################################
    # Finalize the intermediate reads files (from raw CCS corrected reads through split array elements)
    call FF.FinalizeToDir as FinalizeArrayReads {
        input:
            files = [
                ccs_corrected_reads,
                ccs_corrected_reads_index,
                ccs_rejected_reads,
                ccs_rejected_reads_index,
                annotated_ccs_reads,
                annotated_ccs_reads_index,
                longbow_passed_ccs_reads,
                longbow_passed_ccs_reads_index,
                longbow_failed_ccs_reads,
                longbow_failed_ccs_reads_index,
                ccs_reclaimable_reads,
                ccs_reclaimable_reads_index,
                annotated_ccs_reclaimable_reads,
                annotated_ccs_reclaimable_reads_index,
                ccs_reclaimed_reads,
                ccs_reclaimed_reads_index,
                longbow_failed_ccs_unreclaimable_reads,
                longbow_failed_ccs_unreclaimable_reads_index,
                longbow_passed_reads,
                longbow_passed_reads_index,
                longbow_failed_reads,
                longbow_failed_reads_index
            ],
            outdir = intermediate_reads_dir + "/array_bams",
            keyfile = GenerateStaticReport.html_report
    }

    call FF.FinalizeToDir as FinalizeArrayElementReads {
        input:
            files = [
                MergeCbcUmiArrayElements.merged_bam,
                MergeCbcUmiArrayElements.merged_bai,
                MergeLongbowExtractedArrayElements.merged_bam,
                MergeLongbowExtractedArrayElements.merged_bai,
                MergeTranscriptomeAlignedExtractedArrayElements.merged_bam,
                MergeTranscriptomeAlignedExtractedArrayElements.merged_bai,
                MergeGenomeAlignedExtractedArrayElements.merged_bam,
                MergeGenomeAlignedExtractedArrayElements.merged_bai,
            ],
            outdir = intermediate_reads_dir + "/array_element_bams",
            keyfile = GenerateStaticReport.html_report
    }

    ##############################################################################################################
    # Finalize Metrics:
    call FF.FinalizeToDir as FinalizeSamStatsOnInputBam {
        input:
            # an unfortunate hard-coded path here:
            outdir = metrics_out_dir + "/input_bam_stats",
            files = [
                CalcSamStatsOnInputBam.raw_stats,
                CalcSamStatsOnInputBam.summary_stats,
                CalcSamStatsOnInputBam.first_frag_qual,
                CalcSamStatsOnInputBam.last_frag_qual,
                CalcSamStatsOnInputBam.first_frag_gc_content,
                CalcSamStatsOnInputBam.last_frag_gc_content,
                CalcSamStatsOnInputBam.acgt_content_per_cycle,
                CalcSamStatsOnInputBam.insert_size,
                CalcSamStatsOnInputBam.read_length_dist,
                CalcSamStatsOnInputBam.indel_distribution,
                CalcSamStatsOnInputBam.indels_per_cycle,
                CalcSamStatsOnInputBam.coverage_distribution,
                CalcSamStatsOnInputBam.gc_depth
            ],
            keyfile = GenerateStaticReport.html_report
    }

    # Finalize all the 10x metrics here:
    # NOTE: We only run the 10x tool if we have real (non-SIRV) data, so we have to have this conditional here:
    if (! is_SIRV_data) {
        String tenXToolMetricsDir = metrics_out_dir + "/ten_x_tool_metrics"

        ## TODO: Make this consolidate the stats first:
        scatter ( i in range(length(TenxAnnotateArrayElements.output_bam))) {
            call FF.FinalizeToDir as FinalizeTenXRgStats {
                input:
                    files = select_all([
                        TenxAnnotateArrayElements.barcode_stats[i],
                        TenxAnnotateArrayElements.starcode[i],
                        TenxAnnotateArrayElements.stats[i],
                        TenxAnnotateArrayElements.timing_info[i]
                    ]),
                    outdir = tenXToolMetricsDir + "/" + i,
                    keyfile = GenerateStaticReport.html_report
            }
        }
        call FF.FinalizeToDir as FinalizeTenXOverallStats {
            input:
                files = [
                    select_first([Merge10XStats_1.merged_tsv])
                ],
                outdir = tenXToolMetricsDir,
                keyfile = GenerateStaticReport.html_report
        }
    }

    call FF.FinalizeToDir as FinalizeCCSMetrics {
        input:
            files = [ final_ccs_report ],
            outdir = metrics_out_dir + "/ccs_metrics",
            keyfile = GenerateStaticReport.html_report
    }

    ##############################################################################################################
    # Finalize all the Quantification data:
    call FF.FinalizeToDir as FinalizeQuantResults {
        input:
            files = [
                UMIToolsGroup.output_bam,
                UMIToolsGroup.output_tsv,
                CreateCountMatrixFromAnnotatedBam.count_matrix
            ],
            outdir = quant_dir,
            keyfile = GenerateStaticReport.html_report
    }
    # Finalize our anndata objects if we have them:
    if ( ! is_SIRV_data ) {
        call FF.FinalizeToDir as FinalizeProcessedQuantResults {
            input:
                files = select_all([
                    CreateCountMatrixAnndataFromTsv.gene_count_anndata_pickle,
                    CreateCountMatrixAnndataFromTsv.transcript_count_anndata_pickle,
                    CreateCountMatrixAnndataFromTsv.gene_count_anndata_h5ad,
                    CreateCountMatrixAnndataFromTsv.transcript_count_anndata_h5ad,
                ]),
                outdir = quant_dir,
                keyfile = GenerateStaticReport.html_report
        }
    }

    ##############################################################################################################
    # Finalize the report:
    call FF.FinalizeToDir as FinalizeStaticReport {
        input:
            files = [
                GenerateStaticReport.populated_notebook,
                GenerateStaticReport.html_report,
            ],
            outdir = report_dir,
            keyfile = GenerateStaticReport.html_report
    }

    call FF.FinalizeTarGzContents as FinalizeReportFigures {
        input:
            tar_gz_file = GenerateStaticReport.figures_tar_gz,
            outdir = report_dir,
            keyfile = GenerateStaticReport.html_report
    }

    ##############################################################################################################
    # Write out completion file so in the future we can be 100% sure that this run was good:
    call FF.WriteCompletionFile {
        input:
            outdir = base_out_dir + "/",
            keyfile = GenerateStaticReport.html_report
    }
}
