#!/bin/sh

# Copyright (c) 2016-2020 Sentieon Inc. All rights reserved

# *******************************************
# Script to perform TN seq variant calling
# using a Tumor sample with fastq files
# named tumor_1.fastq.gz, tumor_2.fastq.gz
# and data from a Panel of Normals and Cosmic DB
# *******************************************

# Update with the fullpath location of your sample fastq
TUMOR_SM="tumor_sample" #sample name
TUMOR_RGID="rg_$TUMOR_SM" #read group ID
PL="ILLUMINA" #or other sequencing platform
FASTQ_FOLDER="/home/pipeline/samples"
TUMOR_FASTQ_1="$FASTQ_FOLDER/tumor_1.fastq.gz"
TUMOR_FASTQ_2="$FASTQ_FOLDER/tumor_2.fastq.gz" #If using Illumina paired data

# Update with the location of the reference data files
FASTA_DIR="/home/regression/references/b37/"
FASTA="$FASTA_DIR/human_g1k_v37_decoy.fasta"
KNOWN_DBSNP="$FASTA_DIR/dbsnp_138.b37.vcf.gz"
KNOWN_INDELS="$FASTA_DIR/1000G_phase1.indels.b37.vcf.gz"
KNOWN_MILLS="$FASTA_DIR/Mills_and_1000G_gold_standard.indels.b37.vcf.gz"
# Update with the location of the panel of normal and CosmicDB vcf files
PANEL_OF_NORMAL_TNSNV="/home/regression/references/b37/b37_panel_of_normal.TNsnv.vcf"
# We recommend that you create the panel of normal file with the corresponding algorithm that you plan to use for the somatic mutation calling. 
PANEL_OF_NORMAL_TNHAPLOTYPER="/home/regression/references/b37/b37_panel_of_normal.TNhaplotyper.vcf"
COSMIC_DB="/home/regression/references/b37/b37_cosmic_v54_120711.vcf.gz"

# Update with the location of the Sentieon software package and license file
SENTIEON_INSTALL_DIR=/home/release/sentieon-genomics-|release_version|
export SENTIEON_LICENSE=/home/Licenses/Sentieon.lic #or using licsrvr: c1n11.sentieon.com:5443

# Other settings
NT=$(nproc) #number of threads to use in computation, set to number of cores in the server
START_DIR="$PWD/test/TNseq_tumoronly" #Determine where the output files will be stored





# You do not need to modify any of the lines below unless you want to tweak the pipeline

# ************************************************************************************************************************************************************************

# ******************************************
# 0. Setup
# ******************************************
WORKDIR="$START_DIR"
mkdir -p $WORKDIR
LOGFILE=$WORKDIR/run.log
exec >$LOGFILE 2>&1
cd $WORKDIR

# ******************************************
# 1a. Mapping reads with BWA-MEM, sorting for tumor sample
# ******************************************
#The results of this call are dependent on the number of threads used. To have number of threads independent results, add chunk size option -K 10000000 
( $SENTIEON_INSTALL_DIR/bin/sentieon bwa mem -M -R "@RG\tID:$TUMOR_RGID\tSM:$TUMOR_SM\tPL:$PL" -t $NT -K 10000000 $FASTA $TUMOR_FASTQ_1 $TUMOR_FASTQ_2 || echo -n 'error' ) | $SENTIEON_INSTALL_DIR/bin/sentieon util sort -o tumor_sorted.bam -t $NT --sam2bam -i -

# ******************************************
# 2a. Metrics for tumor sample
# ******************************************
$SENTIEON_INSTALL_DIR/bin/sentieon driver -r $FASTA -t $NT -i tumor_sorted.bam --algo MeanQualityByCycle tumor_mq_metrics.txt --algo QualDistribution tumor_qd_metrics.txt --algo GCBias --summary tumor_gc_summary.txt tumor_gc_metrics.txt --algo AlignmentStat --adapter_seq '' tumor_aln_metrics.txt --algo InsertSizeMetricAlgo tumor_is_metrics.txt
$SENTIEON_INSTALL_DIR/bin/sentieon plot GCBias -o tumor_gc-report.pdf tumor_gc_metrics.txt
$SENTIEON_INSTALL_DIR/bin/sentieon plot QualDistribution -o tumor_qd-report.pdf tumor_qd_metrics.txt
$SENTIEON_INSTALL_DIR/bin/sentieon plot MeanQualityByCycle -o tumor_mq-report.pdf tumor_mq_metrics.txt
$SENTIEON_INSTALL_DIR/bin/sentieon plot InsertSizeMetricAlgo -o tumor_is-report.pdf tumor_is_metrics.txt


# ******************************************
# 3a. Remove Duplicate Reads for tumor
# sample. It is possible
# to mark instead of remove duplicates
# by ommiting the --rmdup option in Dedup
# ******************************************
$SENTIEON_INSTALL_DIR/bin/sentieon driver -t $NT -i tumor_sorted.bam --algo LocusCollector --fun score_info tumor_score.txt
$SENTIEON_INSTALL_DIR/bin/sentieon driver -t $NT -i tumor_sorted.bam --algo Dedup --rmdup --score_info tumor_score.txt --metrics tumor_dedup_metrics.txt tumor_deduped.bam 

# ******************************************
# 2a. Coverage metrics for tumor sample
# ******************************************
$SENTIEON_INSTALL_DIR/bin/sentieon driver -r $FASTA -t $NT -i tumor_deduped.bam --algo CoverageMetrics tumor_coverage_metrics

# ******************************************
# 4a. Indel realigner for tumor sample
# ******************************************
$SENTIEON_INSTALL_DIR/bin/sentieon driver -r $FASTA -t $NT -i tumor_deduped.bam --algo Realigner -k $KNOWN_MILLS -k $KNOWN_INDELS tumor_realigned.bam

# ******************************************
# 5a. Base recalibration for tumor sample
# ******************************************
$SENTIEON_INSTALL_DIR/bin/sentieon driver -r $FASTA -t $NT -i tumor_realigned.bam --algo QualCal -k $KNOWN_DBSNP -k $KNOWN_MILLS -k $KNOWN_INDELS tumor_recal_data.table
$SENTIEON_INSTALL_DIR/bin/sentieon driver -r $FASTA -t $NT -i tumor_realigned.bam -q tumor_recal_data.table --algo QualCal -k $KNOWN_DBSNP -k $KNOWN_MILLS -k $KNOWN_INDELS tumor_recal_data.table.post
$SENTIEON_INSTALL_DIR/bin/sentieon driver -t $NT --algo QualCal --plot --before tumor_recal_data.table --after tumor_recal_data.table.post tumor_recal.csv
$SENTIEON_INSTALL_DIR/bin/sentieon plot QualCal -o tumor_recal_plots.pdf tumor_recal.csv

# ******************************************
# 7. Somatic Variant Calling
# ******************************************
$SENTIEON_INSTALL_DIR/bin/sentieon driver -r $FASTA -t $NT -i tumor_realigned.bam -q tumor_recal_data.table --algo TNsnv --tumor_sample $TUMOR_SM --pon $PANEL_OF_NORMAL_TNSNV --cosmic $COSMIC_DB --dbsnp $KNOWN_DBSNP --call_stats_out output-call.stats output-tnsnv.vcf.gz
$SENTIEON_INSTALL_DIR/bin/sentieon driver -r $FASTA -t $NT -i tumor_realigned.bam -q tumor_recal_data.table --algo TNhaplotyper --tumor_sample $TUMOR_SM --pon $PANEL_OF_NORMAL_TNHAPLOTYPER --cosmic $COSMIC_DB --dbsnp $KNOWN_DBSNP output-tnhaplotyper.vcf.gz
