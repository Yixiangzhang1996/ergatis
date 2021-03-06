package NGS::GFF3;

use strict;
use warnings;
use Data::Dumper;
use Bio::Tools::GFF;

sub new {
	my ($class, %args) = @_;
	
	my $self = bless {}, ref($class) || $class;
	$self->_init(\%args);
	return $self;
}

sub _init {
	my ($self, $args) = @_;

	# determine gff version to use; default version = 3
	my $gff_version = 3;
	if( defined $args->{gff_version} ) {
		$gff_version = $args->{gff_version};
	}
	
	my $gff3 = Bio::Tools::GFF->new(-gff_version => $gff_version,
									-file => $args->{file});
	$self->{_gff3} = $gff3;
	$self->{file} = $args->{file};
	$self->{feature_type} = $args->{feature_type};
	
	if( $args->{file} !~ /\>/ && !$args->{object_only} ) {
		$self->{_features} = $self->get_features_array();
	}
}

# 
# Get all features in the GFF3 as an array for initialization.
# Change strand from 0/1 to +/-/.
#
sub get_features_array {
    my ($self)  = @_;
	
    my @features;
    my %id_to_index;
    my %seq_ids;

    while( my $feat = $self->{_gff3}->next_feature ) {

		# if using a specific feat type, skip over the others
		if( defined $self->{feature_type} && $feat->primary_tag ne $self->{feature_type} ) {
			next;
		}
		
		if( $feat->strand == 1 ) {
			$feat->{strand} = "+";
			
		} elsif( $feat->strand == -1 ) {
			$feat->{strand} = "-";
			
		} else {
			$feat->{strand} = ".";
		}

		push @features, $feat;
		

		if( !defined($feat->primary_id) && $self->{_gff3}->gff_version eq "3" ) {
		    print "\nWARNING: skipping line in GFF3 because it had no primary_id (ID) tag:\n".$self->feature_as_string($feat);
			
		} elsif( $self->{_gff3}->gff_version eq "3" ) {
		    $id_to_index{$feat->primary_id} = (scalar(@features) - 1);
			
		} else {
			my @gene_id = $feat->get_tag_values('gene_id');
			$feat->primary_id($gene_id[0]);
		    $id_to_index{$feat->primary_id} = (scalar(@features) - 1);
		}
		
		$seq_ids{$feat->seq_id} = 1;
    }		
	
    $self->{_id_to_index} = \%id_to_index;
    $self->{_seq_ids} = \%seq_ids;
	
    return \@features;
}

sub seq_ids(){
    my ($self) = @_;
    my @seqs;

    foreach (sort keys %{$self->{_seq_ids}}){
	push @seqs, $_;
    }

    return \@seqs;
}

sub reverse_feature_strands {
     my ($self)  = @_;
     
     foreach my $feat (@{$self->{_features}}){
	 if($feat->{strand} eq "+"){
	     $feat->{strand} = "-";
	 }
	 elsif($feat->{strand} eq "-"){
	     $feat->{strand} = "+";
	 }
	 
     }
 }


sub get_feature_by_primary_id {
    my ($self, %args)  = @_;
    die "Must provide a primary_id to retrieve feature by!" if (!defined $args{primary_id});
    
    if(defined ${%{$self->{_id_to_index}}}{$args{primary_id}} ){
	my $index = ${%{$self->{_id_to_index}}}{$args{primary_id}};
	return ${@{$self->{_features}}}[$index];
    }
    else { return; }
}
    
#
# Fetches features with options filters by type, seq_id, strand, and location w/buffer, sorted
#
sub get_features {
    my ($self, %args)  = @_;

    $args{buffer} = 0 if( !defined $args{buffer} );
	
    my @features;
    
    foreach my $feat (@{$self->{_features}}) {

		if( (defined $args{feat_type}) && ($feat->primary_tag ne $args{feat_type}) ) {
			next;
		}
		
		if( (defined $args{seq_id}) && ($feat->seq_id ne $args{seq_id}) ) {
			next;
		}
		
		# be advised that b/c we use "+/-" for strand designation, we use our own values of strand from the _features object
		if( (defined $args{strand}) && ($feat->{strand} ne $args{strand}) ) {
			next;
		} 
		
		if( (defined $args{start}) && (defined $args{end}) ) {
			my $overlap = $self->check_for_overlap({start => ($feat->start - $args{buffer}), 
													end => ($feat->end + $args{buffer}) },
												   {start => $args{start}, 
													end => $args{end} });
			next unless($overlap->{action} ne "none");
			
		}
		
		# we passed all checks
		push @features, $feat;
    }
	
	@features = sort { $a->start <=> $b->start } @features;
    
    return \@features;
}

#
# Get intron regions
#
sub get_intron_regions {
    my ($self, %args)  = @_;
	
    # get lengths of all chromosomes from alignment object
	my $chr_sizes = $args{bam}->sizes;

	my $exon_features = $self->get_features( feat_type => "exon" );

	# get all mrna features whose coordinates will be used to find intron regions
	my %mrnas;
	my $mrna_features = $self->get_flattened_features_by_type_and_chromosome( feat_type => "mRNA" );

	foreach my $mrna (sort {$a->start <=> $b->start} @$mrna_features) {
		my @parent = $mrna->get_tag_values('Parent');
		$mrnas{$mrna->primary_id}->{'parent'} = $parent[0];
	}


	my @intron_features;
	my $id = 1;
	my $prev_end = 0;
	my $first_exon = 0;
	
	foreach my $exon (sort {$a->start <=> $b->start} @$exon_features) {
		my $seq_id = $exon->seq_id;
		my @mrna = $exon->get_tag_values('Parent');
		my $gene = $mrnas{ $mrna[0] }->{'parent'};

		# length of chromosome (comes from alignmenment object)
		my $chromosome_length = $chr_sizes->{$seq_id};
		
		# start intron after 1st exon
		if( ($prev_end + 1) < ($exon->start - 1) && ($prev_end < $chromosome_length) && $first_exon > 0 ) {
			my $region_id = "intron.". $seq_id . "_" . $id;
			my $ig_start = $prev_end + 1;
			my $ig_end = $exon->start - 1;
			
			my $new_feat = Bio::SeqFeature::Generic->new( -seq_id => $seq_id,
														  -start => $ig_start,
														  -end => $ig_end,
														  -strand => $exon->strand,
														  -primary => "intron",
														  -source_tag => "parsed",
														  -display_name => $region_id,
														  -tag => { ID => $region_id,
																	gene_id => $gene }
														  );
			push @intron_features, $new_feat;
			$id++;
		}
		$prev_end = $exon->end;
		# skip the first pass because we only want to start AFTER the first exon
		$first_exon = 1;
	}

	return \@intron_features;
}

#
# Get intergenic regions
#
sub get_intergenic_regions {
    my ($self, %args)  = @_;
	
    # get lengths of all chromosomes from alignment object
	my $chr_sizes = $args{bam}->sizes;
	
	# get all gene features whose coordinates will be used to find intergenic regions
	my $gene_features = $self->get_flattened_features_by_type_and_chromosome( feat_type => $args{feat_type} );


	my @intergenic_features;
	my $prev_end = 0;
	my $prev_gene = "chr_start";
	my $total_features = @$gene_features;
	my $id = 1;
	my %last_gene;

	foreach my $feat (sort {$a->start <=> $b->start} @$gene_features) {
		my $seq_id = $feat->seq_id;
		
		# length of chromosome (comes from alignmenment object)
		my $chromosome_length = $chr_sizes->{$seq_id};
		
		# add region upstream of first gene
		if( ($prev_end + 1) < ($feat->start - 1) && ($prev_end < $chromosome_length) ) {
			my $region_id = "intergenic.". $seq_id . "_" . $id;
			my $ig_start = $prev_end + 1;
			my $ig_end = $feat->start - 1;

			my $between = $prev_gene . "_" . $feat->display_id;
			
			my $new_feat = Bio::SeqFeature::Generic->new( -seq_id => $seq_id,
														  -start => $ig_start,
														  -end => $ig_end,
														  -strand => $feat->strand,
														  -primary => "intergenic",
														  -source_tag => "parsed",
														  -display_name => $region_id,
														  -tag => { ID => $region_id,
																	between => $between
																	}
														  );
			push @intergenic_features, $new_feat;
			$id++;
			
			$last_gene{$seq_id} = {'last_gene' => $feat, 
								   'chromosome_length' => $chromosome_length, 
								   'prev_end' => $feat->end, 
								   'prev_gene' => $feat->display_id };
		}
		$prev_end = $feat->end;
		$prev_gene = $feat->display_id;
	}

	
	# add region downstream from last gene
	if( $total_features > 0 ) {

		foreach my $seq_id (sort {$a cmp $b} keys %last_gene) {
			my $feat = $last_gene{$seq_id}->{'last_gene'};
			my $prev_end = $last_gene{$seq_id}->{'prev_end'};
			my $prev_gene = $last_gene{$seq_id}->{'prev_gene'};
			my $between = $prev_gene . "_chr_end";
			
			my $chromosome_length = $last_gene{$seq_id}->{'chromosome_length'};

			if( $prev_end < $chromosome_length ) {
				my $region_id = "intergenic." . $seq_id . "_" . $id;
				my $ig_start = $prev_end + 1;
				my $ig_end = $chromosome_length;
				
				my $new_feat = Bio::SeqFeature::Generic->new( -seq_id => $seq_id,
															  -start => $ig_start,
															  -end => $ig_end,
															  -strand => $feat->strand,
															  -primary => "intergenic",
															  -source_tag => "parsed", 
															  -display_name => $region_id,
															  -tag => { ID => $region_id,
																		between => $between
																		}
															  );
				push @intergenic_features, $new_feat;
				$id++;
			}
		}
	}

	return \@intergenic_features;
}

sub get_feature_family {
    my ($self, %args)  = @_;

    die "Must define an id to find child features!" if(!defined $args{id});
    die "Must define attribute tags to find child features!" if(!defined $args{tags});

    my $features = $self->get_features(%args);

    my @children;
    
    foreach my $feat (@{$features}){

	my $tag;

	foreach(@{$args{tags}}){
	    if($feat->has_tag($_)){
		$tag = $_;
		last;
	    }
	}
	
	next unless ((defined $tag) && $feat->has_tag($tag));

	my @vals = $feat->get_tag_values($tag);
	my $id = $vals[0];
	
	push @children, $feat if($id eq $args{id});

    }

    return \@children;
}

#retrieves spanned features (optionally by type) grouped by a specified set of attributes tags
#can optionally take an annotation tag, like a gene name, to pull additional information for the new feature
sub get_spanned_features {
    my ($self, %args)  = @_;
	
    die "Must define an attribute tag to group features on for spans!" if(!defined $args{tags});

	my $features;
	if( defined $self->{_features} ) {
		$features = $self->{_features};
	} else {
		$features = $self->get_features(%args);
	}

    my %span_features;
	my %seq_ids;
	my $new_features = $features;

    foreach my $feat ( @{$features} ) {
		
		# assign seq_id
		$seq_ids{ $feat->seq_id } = 1;

		# get tag values
		my $tag;
		foreach( @{$args{tags}} ) {
			$tag = $_;
		}
		my @vals = $feat->get_tag_values($tag);
		my $id = $vals[0];
		
		my $annot = "";
		if( defined $args{annot_tag} && $feat->has_tag($args{annot_tag}) ) {
			my @tvals = $feat->get_tag_values($args{annot_tag});
			$annot = $tvals[0];
		}
		
		if(!defined $span_features{$id}){
			$span_features{$id} = { start => $feat->start,
									end => $feat->end, 
									strand => $feat->{strand},
									seq_id => $feat->seq_id,			    
								};
			
			$span_features{$id}{annot_tag} = $annot;	    
			
		} else {
			
			if($feat->start < $span_features{$id}{start}){
				$span_features{$id}{start} = $feat->start;
			}
			
			if($feat->end > $span_features{$id}{end}){
				$span_features{$id}{end} = $feat->end;
			}
		}
    }

	# replace feature with new spanned coordinates
	# split by seq_id for later sorting
	my %seqfeats;
    foreach my $new_feat (@$new_features) {
		
		my $id = $new_feat->primary_id;
		my $seq_id = $new_feat->seq_id;
		
		if( $span_features{$id} ) {
			$new_feat->start( $span_features{$id}->{start} );
			$new_feat->end( $span_features{$id}->{end} );
			$new_feat->strand( $span_features{$id}->{strand} );
		}

		push @{$seqfeats{$seq_id}}, $new_feat;
	}

	# sort the features
	my $sorted_features;
	foreach my $seq_id (sort {$a cmp $b} keys %seqfeats) {
		push @$sorted_features, sort {$a->start <=> $b->start} @{$seqfeats{$seq_id}};
	}
	
	return $sorted_features;
}


#
# Get all features for:
#  - specific type  (defined in the GFF3 file)
#  - specific seq id
#  - specific location
#
sub get_features_by_location_type_and_chromosome {
    my ($self, %args) = @_;     

    $args{buffer} = 0 if(!defined $args{buffer});

    my @hits;

    my $features = $self->get_features(seq_id => $args{seq_id}, feat_type => $args{feat_type});

    foreach my $feat (@{$features}){
		my $overlap = $self->check_for_overlap({start => ($feat->start - $args{buffer}), end => ($feat->end + $args{buffer}) },
											   {start => $args{start}, end => $args{end} });
		push @hits, $feat if($overlap->{action} ne "none");
    }

    return \@hits;
}

#
# Flattens and merges features based on coordinates
# Also takes an optional buffer to merge closeby features
#
sub get_flattened_features_by_type_and_chromosome {
    my ($self, %args) = @_;     

    $args{buffer} = 1 if( !defined $args{buffer} );
    my @flat;
    my $features;
	
    if( (!defined $args{strand} || $args{strand} eq ".") && defined $args{seq_id} ) {
		$features = $self->get_features(seq_id => $args{seq_id}, feat_type => $args{feat_type}, sorted => 1);
		
	} elsif( defined $args{strand} && defined $args{seq_id} ) {
		$features = $self->get_features(seq_id => $args{seq_id}, feat_type => $args{feat_type}, strand => $args{strand}, sorted => 1);
	
	} elsif( defined $args{strand} && !defined $args{seq_id} ) {
		$features = $self->get_features(feat_type => $args{feat_type}, strand => $args{strand}, sorted => 1);
		
    } else {
		$features = $self->get_features( feat_type => $args{feat_type} );
	}
	
    foreach my $feat ( @{$features} ) {
		my $updated = 0;
		
		# skip features that have the same start/end coords
		if( $feat->start == $feat->end ) {
			print STDERR "WARNING! Feature has the same start/end coordinate: " . $feat->seq_id . " -- " . $feat->primary_id . " --> " . $feat->start . ", " . $feat->end . "\n";
			next;
		}
		
		foreach my $old (@flat) {
			
			# new gene is feat and old gene is old
			my $overlap = $self->check_for_overlap( { start => ( $feat->start - $args{buffer} ), 
													  end => ( $feat->end + $args{buffer} ), 
													  id => $feat->primary_id,
													  buffer => $args{buffer}
												  },
													{ start => $old->{start}, 
													  end => $old->{end}, 
													  id => $old->{id}
												  });

			# if there was an overlap, update the existing feature
			if( $overlap->{action} eq "TAR_INSIDE_ORF" ) {
				$old->{start} = $feat->start;
				$old->{end} = $feat->end;
				$old->{id} .= "_MERGED_" . $feat->primary_id;
				$old->{feat} = $feat;

				$updated = 1;				
				last;
				
			} elsif( $overlap->{action} ne "none" && $overlap->{action} ne "ORF_INSIDE_TAR" ) {
				$old->{start} = $overlap->{start};
				$old->{end} = $overlap->{end};
				$old->{id} .= "_MERGED_" . $feat->primary_id;
				$old->{feat} = $feat;
				
				$updated = 1;
				last;
				
			} elsif($overlap->{action} eq "ORF_INSIDE_TAR"){
				$old->{id} .= "_MERGED_" . $feat->primary_id;
				$old->{feat} = $feat;
				
				$updated = 1;
				last;
			}
		}
		
		# otherwise, add the feature as is
		if( $updated == 0 ) {
			# brand new feature
			push @flat, { seq_id => $feat->seq_id, 
						  start => $feat->start, 
						  end => $feat->end, 
						  id => $feat->primary_id,
						  strand => $feat->{strand},
						  feat => $feat };
		}
    }


	# create new feature with merged data
	my $updated_features;
	
	foreach my $f (@flat) {
		my $new_feat = $f->{feat};
		$new_feat->source_tag('merged');
		$new_feat->primary_id($f->{id});
		$new_feat->start($f->{start});
		$new_feat->end($f->{end});
		
		push @$updated_features, $new_feat;
	}
	
	return $updated_features;
}

#
# Calculates what to do with feature_1 given that we already have feature_2
# also returns the percent of the new gene covered by the old gene
#
sub check_for_overlap {
    my ($self, $new, $old) = @_;
	
	# orf coords
    my $s1 = $new->{start};
    my $e1 = $new->{end};
	
	# tar coords
    my $s2 = $old->{start};
    my $e2 = $old->{end};
	
	# length of orf
    my $nlen = $e1 - $s1;

	# buffered orf coords with overlap buffer
	my $buffer = exists($new->{buffer}) ? $new->{buffer} : 0;
	my $b_s1 = $new->{start} - $buffer;
	my $b_e1 = $new->{end} + $buffer;
	
	my $percent = 0;
	my $overlap = 0;

    if( $b_s1 >= $s2 && $e1 <= $e2 ) {
		# gene 1 inside gene 2, return gene 2
		$percent = sprintf("%.2f", ( ($e1-$s1) / $nlen ) * 100);
		$overlap = $nlen;
		return {action => "ORF_INSIDE_TAR", o_start => $s1, o_end => $e1, nbp_overlap => $overlap, percent => $percent};
		
    } elsif( $s2 >= $b_s1 && $e2 <= $b_e1 ) {
        # gene 2 inside gene 1, return gene 1
		$percent = sprintf("%.2f", ( ($e2-$s2) / $nlen ) * 100);
		$overlap = $e2 - $s2;
		return {action => "TAR_INSIDE_ORF", o_start => $s2, o_end => $e2, nbp_overlap => $overlap, percent => $percent};
		
    } elsif( $b_s1 >= $s2 && $b_s1 <= $e2 && $b_e1 > $e2 ) {
		# gene 1 starts inside gene 2		
		#in these cases we must update the coordinates of the old feature
		$percent = sprintf("%.2f", ( ($e2-$s1) / $nlen ) * 100);
		$overlap = $e2 - $s1;
		return {action => "TAR_START_OUTSIDE_ORF", start => $s2, end => $e1, o_start => $s1, o_end => $e2, nbp_overlap => $overlap, percent => $percent};	
		
    } elsif( $b_e1 >= $s2 && $b_e1 <= $e2 && $b_s1 < $s2 ) { #gene 1 ends inside gene 2
		$percent = sprintf("%.2f", ( ($e1-$s2) / $nlen ) * 100);
		$overlap = $e1 - $s2;
		return {action => "TAR_END_OUTSIDE_ORF", start => $s1, end => $e2, o_start => $s2, o_end => $e1,  nbp_overlap => $overlap, percent => $percent};	
    }

    # if there was no overlap at all, return "none"
    return {action => "none"};
}
    
#
# Write feature out to gff3 file
#
sub write {
    my ($self, $features) = @_;
    $self->{_gff3}->write_feature(@$features);
	$self->{_gff3}->close;
}

#
# Get the feature as a string
#
sub feature_as_string {
    my ($self, $feature) = @_;
    return $self->{_gff3}->gff_string($feature);
}

1;
