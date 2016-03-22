package fingerbank::Util;

=head1 NAME

fingerbank::Util

=head1 DESCRIPTION

Methods that helps simplify code reading

=cut

use strict;
use warnings;

use File::Copy qw(copy move);
use File::Find;
use File::Touch;
use LWP::UserAgent;
use POSIX;

use fingerbank::Constant qw($TRUE $FALSE $FINGERBANK_USER $DEFAULT_BACKUP_RETENTION);
use fingerbank::Config;
use fingerbank::FilePath qw($INSTALL_PATH);

BEGIN {
    use Exporter ();
    our ( @ISA, @EXPORT_OK );
    @ISA = qw(Exporter);
    @EXPORT_OK = qw(
        is_enabled 
        is_disabled
        is_success
        is_error
    );
}

=head1 METHODS

=head2 is_enabled

Is the given configuration parameter considered enabled? y, yes, true, enable, enabled and 1 are all positive values

=cut

sub is_enabled {
    my ($enabled) = @_;
    if ( $enabled && $enabled =~ /^\s*(y|yes|true|enable|enabled|1)\s*$/i ) {
        return $TRUE;
    } else {
        return $FALSE;
    }
}

=head2 is_disabled

Is the given configuration parameter considered disabled? n, no, false, disable, disabled and 0 are all negative values

=cut

sub is_disabled {
    my ($disabled) = @_;
    if ( !defined ($disabled) || $disabled =~ /^\s*(n|no|false|disable|disabled|0)\s*$/i ) {
        return $TRUE;
    } else {
        return $FALSE;
    }
}

=head2 is_success

Returns a true or false value based on if given error code is considered a success or not.

=cut

sub is_success {
    my ($code) = @_;

    return $FALSE if ( $code !~ /^\d+$/ );

    return $TRUE if ($code >= 200 && $code < 300);
    return $FALSE;
}

=head2 is_error

Returns a true or false value based on if given error code is considered an error or not.

=cut

sub is_error {
    my ($code) = @_;

    return $FALSE if ( $code !~ /^\d+$/ );

    return $TRUE if ($code >= 400 && $code < 600);
    return $FALSE;
}

=head2 cleanup_backup_files

Cleanup backup files that have been created while updating a file

=cut

sub cleanup_backup_files {
    my ($file, $keep) = @_;
    my $logger = fingerbank::Log::get_logger;

    $keep //= $DEFAULT_BACKUP_RETENTION;

    # extracting directory and filename from provided info
    my @parts = split('/', $file);
    my $filename = pop @parts;
    my $directory = join('/', @parts);
    my $metaquoted_name = quotemeta($filename);

    my @files;
    # we find all the backup files associated
    # They end with an underscore digits another underscore and another serie of digits
    File::Find::find({wanted => sub {
        /^$metaquoted_name\_[0-9]+\_[0-9+]/ && push @files, $File::Find::name ;
    }}, $directory);

    # we sort them by name as they contain the date
    # so that will give them in ascending order
    @files = sort(@files);
    
    # we remove the amount we want to keep
    foreach my $i (1..$keep){
        pop @files;    
    }

    # all the files remaining are unwanted
    foreach my $file (@files){
        $logger->info("Deleting backup file $file");
        unless(unlink $file){
            $logger->error("Couldn't delete file $file");
        }
    }
}

sub update_file {
    my ( %params ) = @_;
    my $logger = fingerbank::Log::get_logger;

    my ( $status, $status_msg );

    my @require = qw(download_url destination);
    foreach ( @require ) {
        if ( !exists $params{$_} ) {
            $status_msg = "Missing parameter '$_' while trying to update file";
            $logger->warn($status_msg);
            return ( $fingerbank::Status::INTERNAL_SERVER_ERROR, $status_msg );
        }
    }

    my $is_an_update;
    if ( -f $params{'destination'} ) {
        $is_an_update = $TRUE;
    } else {
        $is_an_update = $FALSE;
    }

    $status = fetch_file(%params, $is_an_update ? ('destination' => $params{'destination'} . '.new') : ());

    if ( is_success($status) && $is_an_update ) {
        my $date                    = POSIX::strftime( "%Y%m%d_%H%M%S", localtime );
        my $destination_backup    = $params{'destination'} . "_$date";
        my $destination_new       = $params{'destination'} . ".new";

        my $return_code;

        # We create a backup of the actual file
        $logger->debug("Backing up current file '$params{'destination'}' to '$destination_backup'");
        $return_code = copy($params{'destination'}, $destination_backup);

        # If copy operation succeed
        if ( $return_code == 1 ) {
            # We move the newly downloaded file to the existing one
            $logger->debug("Moving new file to existing one");
            $return_code = move($destination_new, $params{'destination'});
        }

        # Handling error in either copy or move operation
        if ( $return_code == 0 ) {
            $status = $fingerbank::Status::INTERNAL_SERVER_ERROR;
            $logger->warn("An error occured while copying / moving files while updating '$params{'destination'}' : $!");
        }
    }

    if ( is_success($status) ) {
        $status_msg = "Successfully updated file '$params{'destination'}'";
        $logger->info($status_msg);

        return ( $status, $status_msg );
    }

    $status_msg = "An error occured while updating file '$params{'destination'}'";
    $logger->warn($status_msg);

    return ( $status, $status_msg )
}

=head2 fetch_file

Download the latest version of a file

=cut

sub fetch_file {
    my ( %params ) = @_;
    my $logger = fingerbank::Log::get_logger;

    my @require = qw(download_url destination);
    foreach ( @require ) {
        if ( !exists $params{$_} ) {
            $logger->warn("Missing parameter '$_' while trying to fetch file");
            return $fingerbank::Status::INTERNAL_SERVER_ERROR;
        }
    }

    my $Config = fingerbank::Config::get_config();

    unless ( fingerbank::Config::is_api_key_configured() || (exists($params{'api_key'}) && $params{'api_key'} ne "") ) {
        $logger->warn("Can't communicate with Fingerbank project without a valid API key.");
        return $fingerbank::Status::UNAUTHORIZED;
    }

    $logger->debug("Downloading the latest version from '$params{'download_url'}' to '$params{'destination'}'");

    my $ua = fingerbank::Util::get_lwp_client();
    $ua->timeout(60);   # An update query should not take more than 60 seconds

    my $api_key = ( exists($params{'api_key'}) && $params{'api_key'} ne "" ) ? $params{'api_key'} : $Config->{'upstream'}{'api_key'};    
    my %parameters = ( key => $api_key );
    my $url = URI->new($params{'download_url'});
    $url->query_form(%parameters);

    my $status;
    my $res = $ua->get($url);

    if ( $res->is_success ) {
        $status = $fingerbank::Status::OK;
        $logger->info("Successfully fetched '$params{'download_url'}' from Fingerbank project");
        open my $fh, ">", $params{'destination'};
        print {$fh} $res->decoded_content;
        set_file_permissions($params{'destination'});
    } else {
        $status = $fingerbank::Status::INTERNAL_SERVER_ERROR;
        $logger->warn("Failed to download latest version of file '$params{'destination'}' on '$params{'download_url'}' with the following return code: " . $res->status_line);
    }

    return $status;
}

=head2 get_lwp_client

Returns a LWP::UserAgent for WWW interaction

=cut

sub get_lwp_client {
    my $ua = LWP::UserAgent->new;

    my $Config = fingerbank::Config::get_config();

    # Proxy is enabled
    if ( is_enabled($Config->{'proxy'}{'use_proxy'}) ) {
        return $ua if ( !$Config->{'proxy'}{'host'} || !$Config->{'proxy'}{'port'} );

        my $proxy_host = $Config->{'proxy'}{'host'};
        my $proxy_port = $Config->{'proxy'}{'port'};
        my $verify_ssl = ( is_enabled($Config->{'proxy'}{'verify_ssl'}) ) ? $TRUE : $FALSE;

        $ua = LWP::UserAgent->new(ssl_opts => { verify_hostname => $verify_ssl });
        $ua->proxy(['https', 'http', 'ftp'] => "$proxy_host:$proxy_port");
        $ua->protocols_allowed([ 'https', 'http', 'ftp' ]);

        return $ua;
    }

    return $ua;
}

=head2 set_file_permissions

Sets the proper file permissions a downloaded file

=cut

sub set_file_permissions {
    my ($file) = @_;
    my ($login,$pass,$uid,$gid) = getpwnam($FINGERBANK_USER)
        or die "$FINGERBANK_USER not in passwd file";
    chown $uid, $gid, $file;
}

=head2

Touch each database schema file to change timestamp which will lead to invalidate active handles and recreate them

=cut

sub reset_db_handles {
    my ( $self ) = @_;
    my $logger = fingerbank::Log::get_logger;

    my @database_files = ();
    foreach my $schema ( @fingerbank::DB::schemas ) {
        my $database_file = $INSTALL_PATH . "db/" . "fingerbank_$schema.db";
        push(@database_files, $database_file);
    }

    touch(@database_files);
}

=head1 AUTHOR

Inverse inc. <info@inverse.ca>

=head1 COPYRIGHT

Copyright (C) 2005-2015 Inverse inc.

=head1 LICENSE

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301,
USA.

=cut

1;
