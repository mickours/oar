# $Id$
package OAR::Schedulers::Scheduler;

use Data::Dumper;
use strict;
use warnings;
use OAR::IO;
use OAR::Schedulers::GanttHoleStorage;
use OAR::Modules::Judas qw(oar_debug oar_warn oar_error set_current_log_category);
use OAR::Conf qw(init_conf get_conf is_conf get_conf_with_default_param);

# Log category
set_current_log_category('scheduler');

init_conf($ENV{OARCONFFILE});
my @Sched_available_suspended_resource_type;
my $sched_available_suspended_resource_type_tmp = get_conf("SCHEDULER_AVAILABLE_SUSPENDED_RESOURCE_TYPE");
if (!defined($sched_available_suspended_resource_type_tmp)){
    push(@Sched_available_suspended_resource_type, "default");
}else{
    @Sched_available_suspended_resource_type = split(" ",$sched_available_suspended_resource_type_tmp);
}

# Look at resources that we must add for each job
my $Resources_to_always_add_type = get_conf("SCHEDULER_RESOURCES_ALWAYS_ASSIGNED_TYPE");
my @Resources_to_always_add = ();

# Do we log every scheduler's computation ?
my $Log_scheduling = get_conf("SCHEDULER_LOG_DECISIONS");
if (defined($Log_scheduling) and $Log_scheduling ne "yes") { $Log_scheduling = undef; }

#minimum of seconds between each jobs
my $Security_time_overhead = 1;

#minimum of seconds to be considered like a hole in the gantt
my $Minimum_hole_time = 0;

# waiting time when a reservation has not all of its nodes
my $Reservation_waiting_timeout = 300;

# global variables : initialized in init_scheduler function
my %besteffort_resource_occupation;

my $current_time_sec = 0;
my $current_time_sql = "0000-00-00 00:00:00";

# Give initial time in second and sql formats in a hashtable.
sub get_initial_time(){
    my %time = (
                "sec" => $current_time_sec,
                "sql" => $current_time_sql
              );
    return(%time);
}

#Initialize Gantt tables with scheduled reservation jobs, Running jobs, toLaunch jobs and Launching jobs;
# arg1 --> database ref
sub init_scheduler($$$$$$){
    my $dbh = shift;
    my $dbh_ro = shift;
    my $secure_time = shift;
    my $hole_time = shift;
    my $order_part = shift;
    my $resa_admin_waiting_timeout = shift;

    # First get resources that we must add for each reservation jobs
    if (defined($Resources_to_always_add_type)){
        my $tmp_result_state_resources = OAR::IO::get_specific_resource_states($dbh,$Resources_to_always_add_type);
        if (defined($tmp_result_state_resources->{"Alive"})){
            @Resources_to_always_add = @{$tmp_result_state_resources->{"Alive"}};
            oar_debug("[OAR::Schedulers::Scheduler] Resources automatically added to every reservations: @Resources_to_always_add\n");
        }
    }

    $Reservation_waiting_timeout = $resa_admin_waiting_timeout if (defined($resa_admin_waiting_timeout));
    
    if ($secure_time > 1){
        $Security_time_overhead = $secure_time;
    }

    if ($hole_time >= 0){
        $Minimum_hole_time = $hole_time;
    }

    # Take care of the currently (or nearly) running jobs
    # Lock to prevent bipbip update in same time
    OAR::IO::lock_table($dbh,["jobs","assigned_resources","gantt_jobs_predictions","gantt_jobs_resources","job_types","moldable_job_descriptions","resources","job_state_logs","gantt_jobs_predictions_log","gantt_jobs_resources_log"]);
   
    #calculate now date with no overlap with other jobs
    my $previous_ref_time_sec = OAR::IO::get_gantt_date($dbh);
    $current_time_sec = OAR::IO::get_date($dbh);
    if ($current_time_sec < $previous_ref_time_sec){
        # The system is very fast!!!
        $current_time_sec = $previous_ref_time_sec;
    }
    $current_time_sec++;
    $current_time_sql = OAR::IO::local_to_sql($current_time_sec);

    my $reservation_already_there = OAR::IO::get_waiting_reservations_already_scheduled($dbh);
    
    OAR::IO::gantt_flush_tables($dbh, $reservation_already_there, $Log_scheduling);
    OAR::IO::set_gantt_date($dbh,$current_time_sec);
    
    my @initial_jobs = OAR::IO::get_jobs_in_multiple_states($dbh, ["Running","toLaunch","Launching","Finishing","Suspended","Resuming"]);

    my $max_resources = 50;
    #Init the gantt chart with all resources
    my $vec = '';
    foreach my $r (OAR::IO::list_resources($dbh)){
        vec($vec,$r->{resource_id},1) = 1;
        $max_resources = $r->{resource_id} if ($r->{resource_id} > $max_resources);
    }
    my $gantt = OAR::Schedulers::GanttHoleStorage::new($max_resources, $Minimum_hole_time);
    OAR::Schedulers::GanttHoleStorage::add_new_resources($gantt, $vec);

    # Add already scheduled reservations into the gantt
    foreach my $resa (keys(%{$reservation_already_there})){
        my $vec = '';
        foreach my $r (@{$reservation_already_there->{$resa}->{resources}}){
            vec($vec, $r, 1) = 1;
        }
        OAR::Schedulers::GanttHoleStorage::set_occupation( $gantt,
                                            $reservation_already_there->{$resa}->{start_time},
                                            $reservation_already_there->{$resa}->{walltime} + $Security_time_overhead,
                                            $vec
                                          );
        oar_debug("[OAR::Schedulers::Scheduler] init_scheduler : add in gantt already scheduled reservation (moldable id $resa) at $reservation_already_there->{$resa}->{start_time} with walltime=$reservation_already_there->{$resa}->{walltime} on resources @{$reservation_already_there->{$resa}->{resources}}\n");
    }

    foreach my $i (@initial_jobs){
        next if ($i->{assigned_moldable_job} == 0);
        my $mold = OAR::IO::get_current_moldable_job($dbh,$i->{assigned_moldable_job});
        # The list of resources on which the job is running
        my @resource_list = OAR::IO::get_job_current_resources($dbh, $i->{assigned_moldable_job},undef);

        my $date ;
        if ($i->{start_time} == 0) {
            $date = $current_time_sec;
        }elsif ($i->{start_time} + $mold->{moldable_walltime} < $current_time_sec){
            $date = $current_time_sec - $mold->{moldable_walltime};
        }else{
            $date = $i->{start_time};
        }
        oar_debug("[OAR::Schedulers::Scheduler] init_scheduler : add in gantt job $i->{job_id}\n");
        OAR::IO::add_gantt_scheduled_jobs($dbh,$i->{assigned_moldable_job},$date,\@resource_list);

        # Treate besteffort jobs like nothing!
        my $types = OAR::IO::get_current_job_types($dbh,$i->{job_id});
        if (! defined($types->{besteffort})){
            my $job_duration = $mold->{moldable_walltime};
            if ($i->{state} eq "Suspended"){
                # Remove resources of the type specified in SCHEDULER_AVAILABLE_SUSPENDED_RESOURCE_TYPE
                @resource_list = OAR::IO::get_job_current_resources($dbh, $i->{assigned_moldable_job},\@Sched_available_suspended_resource_type);
            }
            if ($i->{suspended} eq "YES"){
                # This job was suspended so we must recalculate the walltime
                $job_duration += OAR::IO::get_job_suspended_sum_duration($dbh,$i->{job_id},$current_time_sec);
            }

            my $vec = '';
            foreach my $r (@resource_list){
                vec($vec, $r, 1) = 1;
            }
            OAR::Schedulers::GanttHoleStorage::set_occupation(  $gantt,
                                      $date,
                                      $job_duration + $Security_time_overhead,
                                      $vec
                                   );
        }else{
            #Stock information about besteffort jobs
            foreach my $j (@resource_list){
                $besteffort_resource_occupation{$j} = $i->{job_id};
            }
        }
    }
    OAR::IO::unlock_table($dbh);

    #Add in Gantt reserved jobs already scheduled
#    my $str_tmp = "state_num ASC";
#    if (is_conf("SCHEDULER_NODE_MANAGER_WAKE_UP_CMD")){
#        $str_tmp .= ", available_upto DESC";
#    }
#    if (!defined($order_part) or ($order_part eq "")){
#        $order_part = $str_tmp;
#    }else{
#        $order_part = "$str_tmp, $order_part";
#    }
    my @Rjobs = OAR::IO::get_waiting_reservation_jobs($dbh);
    foreach my $job (@Rjobs){
        my $job_descriptions = OAR::IO::get_resources_data_structure_current_job($dbh,$job->{job_id});
        # For reservation we take the first moldable job
        my $moldable = $job_descriptions->[0];
        next if (defined($reservation_already_there->{$moldable->[2]}));
        my $available_resources_vector = '';
        #my $alive_resources_vector = '';
        my @tmp_resource_list;
        # Get the list of resources where the reservation will be able to be launched
        push(@tmp_resource_list, OAR::IO::get_resources_in_state($dbh,"Alive"));
        push(@tmp_resource_list, OAR::IO::get_resources_in_state($dbh,"Suspected"));
        #push(@tmp_resource_list, OAR::IO::get_resources_in_state($dbh,"Dead"));
        push(@tmp_resource_list, OAR::IO::get_resources_in_state($dbh,"Absent"));
        #OAR::Schedulers::GanttHoleStorage::pretty_print($gantt);
        my $free_resources_vec = OAR::Schedulers::GanttHoleStorage::get_free_resources(    $gantt,
                                                                            $job->{start_time},
                                                                            $moldable->[1] + $Security_time_overhead,
                                                                       );
        foreach my $r (@tmp_resource_list){
            if (vec($free_resources_vec, $r->{resource_id}, 1) == 1){
                vec($available_resources_vector, $r->{resource_id}, 1) = 1;
            }
        }
        
#        # CM part
#        if (is_conf("SCHEDULER_NODE_MANAGER_WAKE_UP_CMD")){
#            foreach my $r (OAR::IO::get_resources_that_can_be_waked_up($dbh,$job->{start_time} + $moldable->[1] + $Security_time_overhead)){
#                if (vec($free_resources_vec, $r->{resource_id}, 1) == 1){
#                    vec($available_resources_vector, $r->{resource_id}, 1) = 1;
#                }
#            }
#            foreach my $r (OAR::IO::get_resources_that_will_be_out($dbh,$job->{start_time} + $moldable->[1] + $Security_time_overhead)){
#                vec($available_resources_vector, $r->{resource_id}, 1) = 0;
#            }
#        }
#        # CM part
#        else{
#            foreach my $r (OAR::IO::get_resources_in_state($dbh,"Absent")){
#                if (vec($free_resources_vec, $r->{resource_id}, 1) == 1){
#                    vec($available_resources_vector, $r->{resource_id}, 1) = 1;
#                }
#            }
#        }
 
        my @dead_resources;
        foreach my $r (OAR::IO::get_resources_in_state($dbh,"Dead")){
            push(@dead_resources, $r->{resource_id});
        }
        
        my $job_properties = "\'1\'";
        if ((defined($job->{properties})) and ($job->{properties} ne "")){
            $job_properties = $job->{properties};
        }

        my $resource_id_used_list_vector = '';
        my @tree_list;
        foreach my $m (@{$moldable->[0]}){
            my $tmp_properties = "\'1\'";
            if ((defined($m->{property})) and ($m->{property} ne "")){
                $tmp_properties = $m->{property};
            }
            my $tmp_tree;
            ## Try first with only alive nodes
            #$tmp_tree = OAR::IO::get_possible_wanted_resources($dbh_ro,$alive_resources_vector,$resource_id_used_list_vector,\@dead_resources,"$job_properties AND $tmp_properties", $m->{resources}, $order_part);
            #if (!defined($tmp_tree)){
            $tmp_tree = OAR::IO::get_possible_wanted_resources($dbh_ro,$available_resources_vector,$resource_id_used_list_vector,\@dead_resources,"$job_properties AND $tmp_properties", $m->{resources}, "".$order_part);
            #}
            $tmp_tree = OAR::Schedulers::ResourceTree::delete_unnecessary_subtrees($tmp_tree);
            push(@tree_list, $tmp_tree);
            my @leafs = OAR::Schedulers::ResourceTree::get_tree_leafs($tmp_tree);
            foreach my $l (@leafs){
                vec($resource_id_used_list_vector, OAR::Schedulers::ResourceTree::get_current_resource_value($l), 1) = 1;
            }
        }
       
        # A SUPPRIMER????
        my @res_trees;
        my @resources;
        foreach my $t (@tree_list){
            #my $minimal_tree = OAR::Schedulers::ResourceTree::delete_unnecessary_subtrees($t);
            push(@res_trees, $t);
            foreach my $r (OAR::Schedulers::ResourceTree::get_tree_leafs($t)){
                push(@resources, OAR::Schedulers::ResourceTree::get_current_resource_value($r));
            }
        }

        if ($#resources >= 0){
            # We can schedule the job
            my $vec = '';
            foreach my $r (@resources){
                vec($vec, $r, 1) = 1;
            }
            OAR::Schedulers::GanttHoleStorage::set_occupation(  $gantt,
                                      $job->{start_time},
                                      $moldable->[1] + $Security_time_overhead,
                                      $vec
                                 );
            # Update database
            push(@resources, @Resources_to_always_add);
            OAR::IO::add_gantt_scheduled_jobs($dbh,$moldable->[2],$job->{start_time},\@resources);
            oar_debug("[OAR::Schedulers::Scheduler] Treate waiting reservation $job->{job_id}: add in gantt values\n");
            OAR::IO::set_job_message($dbh,$job->{job_id},"");
        }else{
            oar_warn("[OAR::Schedulers::Scheduler] Treate waiting reservation $job->{job_id}: cannot find resources for this reservation, did you remove some resources or change states into Dead???\n");
            OAR::IO::set_job_message($dbh,$job->{job_id},"Not able to find resources for this reservation");
        }
    }
}


# launch right reservation jobs
# arg1 : database ref
# arg2 : queue name
# return 1 if there is at least a job to treate, 2 if besteffort jobs must die
sub treate_waiting_reservation_jobs($$){
    my $dbh = shift;
    my $queueName = shift;

    oar_debug("[OAR::Schedulers::Scheduler] treate_waiting_reservation_jobs: Search for waiting reservations in $queueName queue\n");

    my $return = 0;

    my @arrayJobs = OAR::IO::get_waiting_reservation_jobs_specific_queue($dbh,$queueName);
    # See if there are reserved jobs to launch
    foreach my $job (@arrayJobs){
        my $job_descriptions = OAR::IO::get_resources_data_structure_current_job($dbh,$job->{job_id});
        my $moldable = $job_descriptions->[0];
    
        my $start = $job->{start_time};
        my $max = $moldable->[1];
        # Test if the job is in the past
        if ($current_time_sec > $start+$max ){
            oar_warn("[OAR::Schedulers::Scheduler] treate_waiting_reservation_jobs :  Reservation $job->{job_id} in ERROR\n");
            OAR::IO::set_job_state($dbh, $job->{job_id}, "Error");
            OAR::IO::set_job_message($dbh,$job->{job_id},"Reservation has expired and it cannot be started.");
            $return = 1;
        }
        my @resa_alive_resources = OAR::IO::get_gantt_Alive_resources_for_job($dbh,$moldable->[2]);
        # test if the job is going to be launched and there is no Alive node
        if (($#resa_alive_resources < 0) && ($job->{start_time} <= $current_time_sec)){
            oar_warn("[OAR::Schedulers::Scheduler] Reservation $job->{job_id} is in waiting mode because no resource is present\n");
            OAR::IO::set_gantt_job_startTime($dbh,$moldable->[2],$current_time_sec + 1);
        }elsif($job->{start_time} <= $current_time_sec){
            my @resa_resources = OAR::IO::get_gantt_resources_for_job($dbh,$moldable->[2]);
            if ($job->{start_time} + $Reservation_waiting_timeout > $current_time_sec){
                if ($#resa_resources > $#resa_alive_resources){
                    # we have not the same number of nodes than in the query --> wait the specified timeout
                    oar_warn("[OAR::Schedulers::Scheduler] Reservation $job->{job_id} is in waiting mode because all nodes are not yet available.\n");
                    OAR::IO::set_gantt_job_startTime($dbh,$moldable->[2],($current_time_sec + 1));
                }
            }else{
                #Check if resources are in Alive state otherwise remove them, the job is going to be launched
                foreach my $r (@resa_resources){
                    my $resource_info = OAR::IO::get_resource_info($dbh,$r);
                    if ($resource_info->{state} ne "Alive"){
                        oar_warn("[OAR::Schedulers::Scheduler] Reservation $job->{job_id}: remove resource $r because it state is $resource_info->{state}\n");
                        OAR::IO::remove_gantt_resource_job($dbh, $moldable->[2], $r);
                    }
                }
                if ($#resa_resources > $#resa_alive_resources){
                    OAR::IO::add_new_event($dbh,"SCHEDULER_REDUCE_NB_NODES_FOR_RESERVATION",$job->{job_id},"[OAR::Schedulers::Scheduler] Reduce the number of resources for the job $job->{job_id}.");
                }
            }
        }
    }

    return($return);
}


# check for jobs with reservation
# arg1 : database ref
# arg2 : queue name
# return 1 if there is at least a job to treate else 0
sub check_reservation_jobs($$$$){
    my $dbh = shift;
    my $dbh_ro = shift;
    my $queue_name = shift;
    my $order_part = shift;

    oar_debug("[OAR::Schedulers::Scheduler] check_reservation_jobs: Check for new reservation in the $queue_name queue\n");

    my $return = 0;

    #Init the gantt chart with all resources
    my $max_resources = 50;
    my $vec = '';
    foreach my $r (OAR::IO::list_resources($dbh)){
        vec($vec,$r->{resource_id},1) = 1;
        $max_resources = $r->{resource_id} if ($r->{resource_id} > $max_resources);
    }
    my $gantt = OAR::Schedulers::GanttHoleStorage::new($max_resources, $Minimum_hole_time);
    OAR::Schedulers::GanttHoleStorage::add_new_resources($gantt, $vec);

    # Find jobs to check
    my @jobs_to_sched = OAR::IO::get_waiting_toSchedule_reservation_jobs_specific_queue($dbh,$queue_name);
    if ($#jobs_to_sched >= 0){
        # Build gantt diagram of other jobs
        # Take care of currently scheduled jobs except besteffort jobs if queue_name is not besteffort
        my ($order, %already_scheduled_jobs) = OAR::IO::get_gantt_scheduled_jobs($dbh);
        foreach my $i (keys(%already_scheduled_jobs)){
            my $types = OAR::IO::get_current_job_types($dbh,$i);
            if ((! defined($types->{besteffort})) or ($queue_name eq "besteffort")){
                my @resource_list = @{$already_scheduled_jobs{$i}->[3]};
                my $job_duration = $already_scheduled_jobs{$i}->[1];
                if ($already_scheduled_jobs{$i}->[4] eq "Suspended"){
                    # Remove resources of the type specified in SCHEDULER_AVAILABLE_SUSPENDED_RESOURCE_TYPE
                    @resource_list = OAR::IO::get_job_current_resources($dbh, $already_scheduled_jobs{$i}->[7],\@Sched_available_suspended_resource_type);
                    next if ($#resource_list < 0);
                }
                if ($already_scheduled_jobs{$i}->[8] eq "YES"){
                    # This job was suspended so we must recalculate the walltime
                    $job_duration += OAR::IO::get_job_suspended_sum_duration($dbh,$i,$current_time_sec);
                }

                my $vec = '';
                foreach my $r (@resource_list){
                    vec($vec, $r, 1) = 1;
                }
                OAR::Schedulers::GanttHoleStorage::set_occupation(  $gantt,
                                          $already_scheduled_jobs{$i}->[0],
                                          $job_duration + $Security_time_overhead,
                                          $vec
                                       );
            }
        }
    }
    foreach my $job (@jobs_to_sched){
        my $job_descriptions = OAR::IO::get_resources_data_structure_current_job($dbh,$job->{job_id});
        # It is a reservation, we take care only of the first moldable job
        my $moldable = $job_descriptions->[0];
        my $duration = $moldable->[1];

        #look if reservation is too old
        if ($current_time_sec >= ($job->{start_time} + $duration)){
            oar_warn("[OAR::Schedulers::Scheduler] check_reservation_jobs: Cancel reservation $job->{job_id}, job is too old\n");
            OAR::IO::set_job_message($dbh, $job->{job_id}, "Reservation too old");
            OAR::IO::set_job_state($dbh, $job->{job_id}, "toError");
        }else{
            if ($job->{start_time} < $current_time_sec){
                $job->{start_time} = $current_time_sec;
                #OAR::IO::set_running_date_arbitrary($dbh,$job->{job_id},$current_time_sql);
            }
            
            my $available_resources_vector = '';
            my @tmp_resource_list;
            # Get the list of resources where the reservation will be able to be launched
            push(@tmp_resource_list, OAR::IO::get_resources_in_state($dbh,"Alive"));
            push(@tmp_resource_list, OAR::IO::get_resources_in_state($dbh,"Absent"));
            push(@tmp_resource_list, OAR::IO::get_resources_in_state($dbh,"Suspected"));
            foreach my $r (@tmp_resource_list){
                vec($available_resources_vector, $r->{resource_id}, 1) = 1;
            }

            my @dead_resources;
            foreach my $r (OAR::IO::get_resources_in_state($dbh,"Dead")){
                push(@dead_resources, $r->{resource_id});
            }
            
#            my $str_tmp = "state_num ASC";
#            if (is_conf("SCHEDULER_NODE_MANAGER_WAKE_UP_CMD")){
#                $str_tmp .= ", available_upto DESC";
#            }
#            if (!defined($order_part) or ($order_part eq "")){
#                $order_part = $str_tmp;
#            }else{
#                $order_part = "$str_tmp, $order_part";
#            }
            
            my $job_properties = "\'1\'";
            if ((defined($job->{properties})) and ($job->{properties} ne "")){
                $job_properties = $job->{properties};
            }

            #my $resource_id_used_list_vector = '';
            my @tree_list;
            foreach my $m (@{$moldable->[0]}){
                my $tmp_properties = "\'1\'";
                if ((defined($m->{property})) and ($m->{property} ne "")){
                    $tmp_properties = $m->{property};
                }
                my $tmp_tree = OAR::IO::get_possible_wanted_resources($dbh_ro,$available_resources_vector,undef,\@dead_resources,"$job_properties AND $tmp_properties", $m->{resources}, $order_part);
                push(@tree_list, $tmp_tree);
                #my @leafs = OAR::Schedulers::ResourceTree::get_tree_leafs($tmp_tree);
                #foreach my $l (@leafs){
                #    vec($resource_id_used_list_vector, OAR::Schedulers::ResourceTree::get_current_resource_value($l), 1) = 1;
                #}
            }
            my @hole = OAR::Schedulers::GanttHoleStorage::find_first_hole($gantt,$job->{start_time}, $duration + $Security_time_overhead, \@tree_list, 30);
            if ($hole[0] == $job->{start_time}){
                # The reservation can be scheduled
                my @res_trees;
                my @resources;
                foreach my $t (@{$hole[1]}){
                    #my $minimal_tree = OAR::Schedulers::ResourceTree::delete_unnecessary_subtrees($t);
                    push(@res_trees, $t);
                    foreach my $r (OAR::Schedulers::ResourceTree::get_tree_leafs($t)){
                        push(@resources, OAR::Schedulers::ResourceTree::get_current_resource_value($r));
                    }
                }
        
                # We can schedule the job
                oar_warn("[OAR::Schedulers::Scheduler] check_reservation_jobs: Confirm reservation $job->{job_id} and add in gantt (@resources)\n");
                my $vec = '';
                foreach my $r (@resources){
                    vec($vec, $r, 1) = 1;
                }
                OAR::Schedulers::GanttHoleStorage::set_occupation(  $gantt,
                                          $job->{start_time},
                                          $duration + $Security_time_overhead,
                                          $vec
                                       );
                # Update database
                push(@resources, @Resources_to_always_add);
                OAR::IO::add_gantt_scheduled_jobs($dbh,$moldable->[2],$job->{start_time},\@resources);
                OAR::IO::set_job_state($dbh, $job->{job_id}, "toAckReservation");
            }else{           
                oar_warn("[OAR::Schedulers::Scheduler] check_reservation_jobs: Cancel reservation $job->{job_id}, not enough nodes\n");
                OAR::IO::set_job_state($dbh, $job->{job_id}, "toError");
                if ($hole[0] == OAR::Schedulers::GanttHoleStorage::get_infinity_value()){
                    OAR::IO::set_job_message($dbh, $job->{job_id}, "This reservation cannot be run");
                }else{
                    OAR::IO::set_job_message($dbh, $job->{job_id}, "This reservation may be run at ".OAR::IO::local_to_sql($hole[0]));
                }
            }
        }
        OAR::IO::set_job_resa_state($dbh, $job->{job_id}, "Scheduled");
        $return = 1;
    }
    return($return);
}


# Detect if there are besteffort jobs to kill
# arg1 --> database ref
# return 1 if there is at least 1 job to frag otherwise 0
sub check_jobs_to_kill($){
    my $dbh = shift;

    oar_debug("[OAR::Schedulers::Scheduler] check_jobs_to_kill: check besteffort jobs\n");
    my $return = 0;
    my %nodes_for_jobs_to_launch = OAR::IO::get_gantt_resources_for_jobs_to_launch($dbh,$current_time_sec);
    my %fragged_jobs = ();
    foreach my $r (keys(%nodes_for_jobs_to_launch)){
        if (defined($besteffort_resource_occupation{$r})) {
            oar_debug("[OAR::Schedulers::Scheduler] check_jobs_to_kill: resource $r is needed for job $nodes_for_jobs_to_launch{$r}, besteffort job $besteffort_resource_occupation{$r} must be killed\n");
            unless (defined($fragged_jobs{$besteffort_resource_occupation{$r}})) {
                OAR::IO::add_new_event($dbh,"BESTEFFORT_KILL",$besteffort_resource_occupation{$r},"[OAR::Schedulers::Scheduler] kill the besteffort job $besteffort_resource_occupation{$r}");
                OAR::IO::lock_table($dbh,["frag_jobs","event_logs","jobs"]);
                OAR::IO::frag_job($dbh, $besteffort_resource_occupation{$r});
                OAR::IO::unlock_table($dbh);
                $return = 1;
                $fragged_jobs{$besteffort_resource_occupation{$r}} = 1;
            }
        }
     }
     return($return);
}



# Detect if there are jobs to launch
# arg1 --> database ref
# return 1 if there is at least 1 job to launch otherwise 0
sub check_jobs_to_launch($){
    my $dbh = shift;

    oar_debug("[OAR::Schedulers::Scheduler] check_jobs_to_launch: check jobs with a start time <= $current_time_sql\n");
    my $return_code = 0;
    my %jobs_to_launch = OAR::IO::get_gantt_jobs_to_launch($dbh,$current_time_sec);
    
    foreach my $i (keys(%jobs_to_launch)){
        oar_debug("[OAR::Schedulers::Scheduler] check_jobs_to_launch: set job $i in state toLaunch ($current_time_sql)\n");
        # We must look at reservations to not go after the initial stop time
        my $mold = OAR::IO::get_current_moldable_job($dbh,$jobs_to_launch{$i}->[0]);
        my $job = OAR::IO::get_job($dbh,$i);
        if (($job->{reservation} eq "Scheduled") and ($job->{start_time} < $current_time_sec)){
            my $max_time = $mold->{moldable_walltime} - ($current_time_sec - $job->{start_time});
            OAR::IO::set_moldable_job_max_time($dbh,$jobs_to_launch{$i}->[0], $max_time);
            OAR::IO::set_gantt_job_startTime($dbh,$jobs_to_launch{$i}->[0],$current_time_sec);
            oar_warn("[OAR::Schedulers::Scheduler] Reduce job ($i) walltime to $max_time instead of $mold->{moldable_walltime}\n");
            OAR::IO::add_new_event($dbh,"REDUCE_RESERVATION_WALLTIME",$i,"Change walltime from $mold->{moldable_walltime} to $max_time");
        }
        my $running_date = $current_time_sec;
        if ($running_date < $job->{submission_time}){
            $running_date = $job->{submission_time};
        }
        OAR::IO::set_running_date_arbitrary($dbh,$i,$running_date);
        OAR::IO::set_assigned_moldable_job($dbh,$i,$jobs_to_launch{$i}->[0]);
        
        #TODO: to remove
        #foreach my $r (@{$jobs_to_launch{$i}->[1]}){
        #    OAR::IO::add_resource_job_pair($dbh,$jobs_to_launch{$i}->[0],$r);
        #}
        #TODO option if insert_from_file is not enable:

        my $insert_from_file = get_conf_with_default_param("INSERTS_FROM_FILE", "no");
        if ($insert_from_file eq 'yes') {
          OAR::IO::add_resource_job_pairs_from_file($dbh,$jobs_to_launch{$i}->[0],$jobs_to_launch{$i}->[1]);
        } else {
          OAR::IO::add_resource_job_pairs($dbh,$jobs_to_launch{$i}->[0],$jobs_to_launch{$i}->[1]);
        }

        OAR::IO::set_job_state($dbh, $i, "toLaunch");
        $return_code = 1;
    }

    return($return_code);
}


#Update gantt visualization tables with new scheduling
#arg : database ref
sub update_gantt_visu_tables($){
    my $dbh = shift;

    OAR::IO::update_gantt_visualization($dbh); 
}

# Look at nodes that are unused for a duration
sub get_idle_nodes($$$){
    my $dbh = shift;
    my $idle_duration = shift;
    my $sleep_duration = shift;

    my %nodes = OAR::IO::search_idle_nodes($dbh, $current_time_sec);
    my $tmp_time = $current_time_sec - $idle_duration;
    my @res;
    foreach my $n (keys(%nodes)){
        if ($nodes{$n} < $tmp_time){
            # Search if the node has enough time to sleep
            my $tmp = OAR::IO::get_next_job_date_on_node($dbh,$n);
            if (!defined($tmp) or ($tmp - $sleep_duration > $current_time_sec)){
                push(@res, $n);
            }
        }
    }
    return(@res);
}

# Get nodes where the scheduler wants to schedule jobs but which is in the
# Absent state
sub get_nodes_to_wake_up($){
    my $dbh = shift;
    my $wakeup_time = get_conf_with_default_param("SCHEDULER_NODE_MANAGER_WAKEUP_TIME", 1);
    return(OAR::IO::get_gantt_hostname_to_wake_up($dbh, $current_time_sec, $wakeup_time));
}

return(1);
