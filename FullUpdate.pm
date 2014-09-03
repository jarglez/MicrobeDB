#Copyright (C) 2011 Morgan G.I. Langille
#Author contact: morgan.g.i.langille@gmail.com

#This file is part of MicrobeDB.

#MicrobeDB is free software: you can redistribute it and/or modify
#it under the terms of the GNU General Public License as published by
#the Free Software Foundation, either version 3 of the License, or
#(at your option) any later version.

#MicrobeDB is distributed in the hope that it will be useful,
#but WITHOUT ANY WARRANTY; without even the implied warranty of
#MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#GNU General Public License for more details.

#You should have received a copy of the GNU General Public License
#along with MicrobeDB.  If not, see <http://www.gnu.org/licenses/>.

package MicrobeDB::FullUpdate;

#inherit common methods from the MicroDB class
use base ("MicrobeDB::MicrobeDB");
use DBI;
use Log::Log4perl qw(get_logger :nowarn);

use strict;
use warnings;
use Carp;
use File::Temp qw/ tempfile/;

use MicrobeDB::GenomeProject;
use MicrobeDB::Replicon;
use MicrobeDB::Gene;
use MicrobeDB::Search;

my @FIELDS;
BEGIN { @FIELDS = qw(dl_directory version_id dbh use_bulk_load); }

use fields  @FIELDS;

my $logger = Log::Log4perl->get_logger();

sub new {

	my ( $class, %arg ) = @_;

	#bless and restrict the object
	my $self = fields::new($class);

	#Set each attribute that is given as an arguement
	foreach ( keys(%arg) ) {
		$self->$_( $arg{$_} );
	}
	if(defined($self->dl_directory)){
	    $logger->info("Using download directory " . $self->dl_directory);
	}


	if(defined($self->version_id())){
	    my $version_id=$self->version_id();
	    #check if this version is already made
	    my $so = new MicrobeDB::Search();
	    my ($version)=$so->table_search('version',{version_id=>$version_id});

	    unless(defined($version)){
		$logger->debug("Making new version because we couldn't find version with version_id: $version_id");
		$self->version_id($self->_new_version()); 
	    }
	}else{
	    
	    $logger->debug("No version_id specified, so going to create a new one.");
	    $self->version_id( $self->_new_version() );
	}

	if(!defined($self->use_bulk_load)) {
	    $self->use_bulk_load( 0 );
	}
	
	return $self;
}

#Creates a new record in the version table and returns the version number
sub _new_version {
	my ($self) = @_;
	my $dbh = $self->dbh();

	my $dir = $self->dl_directory();
	unless($dir){
	    $logger->fatal("A download directory must be supplied if creating a new version");
	    croak("A download directory must be supplied if creating a new version");
	}
	#use the date from the download directory name or use the current date
	my $current_date;
	if ( $dir =~ /(\d{4}\-\d{2}\-\d{2})/ ) {
		$current_date = $1;
	} else {
		$current_date = `date +%F`;
		chomp($current_date);
	}
	$logger->debug("Using datestamp $current_date");

	my $version_id = $self->version_id();
	#Create new version record
	my $sth;
	if(defined($version_id)){
	    $sth = $dbh->prepare( qq{INSERT version (version_id,dl_directory,version_date)VALUES ($version_id,'$dir', '$current_date')} );
	}else{
	    $sth = $dbh->prepare( qq{INSERT version (dl_directory,version_date)VALUES ('$dir', '$current_date')} );
	}
	#Create new version record
	$sth->execute();

	#This should return the auto_increment number that was just updated
	my $version = $dbh->last_insert_id( undef, undef, undef, undef );

	#If it is the custom version (i.e. version_id ==0) then we need to update the insert since auto increment gives a new id if set to 0
	if(defined($version_id)&& $version_id ==0){
	    $dbh->do(qq{UPDATE version SET version_id=0 where version_id=$version});
	    $version=$version_id;
	};
	$logger->info("Created new MicrobeDB version $version");
	
	return $version;

}


#takes a GenomeProject object and adds it to the database including embedded Replicons and Genes
sub update_genomeproject {
	my ( $self, $gpo ) = @_;

	#Need to create a new db connection (even if already set before), since this can be called in parallel
	$self->dbh($self->_db_connect());

	#Set the version id
	$gpo->version_id( $self->version_id );

	#insert into genomeproject table
	my $gpv_id = $self->_insert_record( $gpo, 'genomeproject' );

	#insert into taxonomy table
	my $tax_id = $self->_insert_record( $gpo, 'taxonomy' );

	#Check to see if there are embedded replicon objects
	if ( defined( $gpo->replicons ) ) {

		#handle each replicon
		foreach my $rep_obj ( @{ $gpo->replicons } ) {

			#Set the version id
			$rep_obj->version_id( $self->version_id );

			#Set the genome project id that was just created
			$rep_obj->gpv_id($gpv_id);

			#insert into replicon table
			my $rpv_id = $self->_insert_record( $rep_obj, 'replicon' );

                        #add rpv_id to our object manually
			$rep_obj->rpv_id($rpv_id);

			#Check to see if there are embedded gene objects
			if ( defined( $rep_obj->genes ) ) {

				#handle each gene
				foreach my $gene_obj ( @{ $rep_obj->genes } ) {

					#Set the version id
					$gene_obj->version_id( $self->version_id );

					#Set the genome project id that was just created
					$gene_obj->gpv_id($gpv_id);

					#Set the replicon version id that was just created
					$gene_obj->rpv_id($rpv_id);

					# Insert into gene table unless we've been told
					# to do bulk loading
					unless($self->use_bulk_load) {
					    my $gene_id = $self->_insert_record( $gene_obj, 'gene' );
					}

				}

				# Do bulk loading of genes if we've been told to
				if(@{ $rep_obj->genes } && $self->use_bulk_load) {
				    $self->_bulk_insert_record($rep_obj->genes, 'gene');
				}
			}
		}
	}


}

#Replaces the existing object with the object that is given
sub replace {
	my ( $self, $replace_obj ) = @_;

	#do a replace in the database for each of the tables represented in the object
	#Note: this is not very effiecient because in most cases not all tables would need to be changed
	foreach my $table ( $replace_obj->table_names() ) {
		$self->_insert_record( $replace_obj, $table );
	}

}

sub dbh{
    my ($self,$dbh) = @_;

    #Set the new value for the attribute if given
    $self->{dbh} = $dbh if defined($dbh);

    if(defined($self->{dbh})){
	return $self->{dbh};
    }else{
	$self->{dbh}=$self->_db_connect();
        return $self->{dbh};
    }
}


#inserts a record in the database
#Requires the table name, an array ref of fields and an array ref of values
#Returns the primary key for the record that was created
sub _insert_record {
	my ( $self, $object, $table_name ) = @_;

	my $dbh = $self->dbh;

	my @fields = $object->field_names($table_name);

	my @values;
	foreach (@fields) {
		push( @values, $object->$_ );
	}

	#Need to add back ticks around each field name because certain fields (eg. order) will cause problems
	my @new_fields;
	foreach (@fields) {
		push( @new_fields, "`$_`" );
	}

	#Make the array of fields into a comma seperated string
	my $fields = join( ',', @new_fields );

	#Makes a string of ?'s so we can bind to them later
	#Note: always bind the values because it looks after converting undef to null
	my $bind = join( ',', ('?') x @values );

	#Use REPLACE instead of INSERT so this method can be used for both inserts or replacements
	my $sql = "REPLACE $table_name ($fields) VALUES ($bind)";

	#Create new genomeproject recordicrobedb
	my $sth = $dbh->prepare($sql);

	#call the statement
	$sth->execute(@values);

	#This should return the auto_increment number that was just updated
	return $dbh->last_insert_id( undef, undef, undef, undef );

}

sub _bulk_insert_record {
    my ($self, $object_ary, $table_name ) = @_;

    my $dbh = $self->dbh;
    
    my ($fh, $filename) = tempfile();

    # Fetch the fields from the first record
    my @fields = $object_ary->[0]->field_names($table_name);

    # Make out list of fields for the load statement
    #Need to add back ticks around each field name because certain fields (eg. order) will cause problems
    my $fields_text = join ",", map { qq/`$_`/ } @fields;

    # Go through each of the objects we've been given and 
    # write them out to a temp file
    foreach my $obj ( @{ $object_ary } ) {
	my @values;
	foreach (@fields) {
	    push( @values, $obj->$_ );
	}

	my $line = join "\t", map { qq/"$_"/ } @values;
	print {$fh} "$line\n";
	
    }

    my $sql = "LOAD DATA LOCAL INFILE '$filename' REPLACE INTO TABLE $table_name COLUMNS TERMINATED BY '\t' ENCLOSED BY '\"' ( $fields_text )";

    # Close the temp file we just wrote the bulk rows to
    close $fh;

    # Prepare the bulk load statement
    my $sth = $dbh->prepare($sql);

    # Execute the bulk load
    $sth->execute();
}

1;

