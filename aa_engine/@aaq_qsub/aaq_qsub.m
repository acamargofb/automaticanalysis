classdef aaq_qsub<aaq
    properties
        scheduler = [];
        jobnotrun = [];
        taskstomonitor = [];
    end
    methods
        function [obj]=aaq_qsub(aap)
            global aaworker;
            global aaparallel;
            try
                obj.scheduler=cbu_scheduler('custom',{'compute',aaparallel.numberofworkers,4,24*3600,aaworker.parmpath});
            catch ME
                warning('Cluster computing is not supported!\n');
                warning('\nERROR in %s:\n  line %d: %s\n',ME.stack.file, ME.stack.line, ME.message);
                obj.scheduler=[];
            end
            obj.aap=aap;
        end
        %% Queue jobs on Qsub:
        %  Queue job
        %  Watch output files
        
        % Run all tasks on the queue
        function [obj]=runall(obj,dontcloseexistingworkers,waitforalljobs)
            global aaworker
            
            % Check number of jobs & monitored files
            njobs=length(obj.jobqueue);
            
            % We have already submitted some of these jobs
            submittedJobs = 1:length(obj.jobnotrun);
            obj.jobnotrun = true(njobs,1);
            obj.jobnotrun(submittedJobs) = false;
            
            while any(obj.jobnotrun) && ~waitforalljobs
                
                % Lets not overload the filesystem
                pause(1);
                
                for i=1:njobs
                    if (obj.jobnotrun(i))
                        % Find out whether this job is ready to be allocated by
                        % checking dependencies (done_ flags)
                        readytorun=true;
                        for j=1:length(obj.jobqueue(i).tobecompletedfirst)
                            if (~exist(obj.jobqueue(i).tobecompletedfirst{j},'file'))
                                readytorun=false;
                            end
                        end
                        
                        if (readytorun)
                            % Add a job to the queue
                            job=obj.jobqueue(i);
                            obj.aap.acq_details.root=aas_getstudypath(obj.aap,job.k);
                            % Assign an aap to the job!
                            job.aap=obj.aap;
                            % Run the job
                            obj.qsub_q_job(job);
                            obj.jobnotrun(i)=false;
                        end
                    end
                end
                
                taskreported = [];
                
                for ftmind=1:numel(obj.taskstomonitor)                    
                    JobID = obj.taskstomonitor(ftmind);
                    Task = obj.scheduler.Jobs([obj.scheduler.Jobs.ID] == JobID).Tasks;
                    moduleName = Task.InputArguments{1}.tasklist.main.module(Task.InputArguments{3}).name;
                    state = Task.State;
                    if ~isempty(Task.Error), state = 'error'; end
                    
                    switch state
                        case 'finished'
                            if isempty(Task.FinishTime), continue; end
                            dtvs = dts2dtv(Task.CreateTime);
                            dtvf = dts2dtv(Task.FinishTime);
                            msg = sprintf('MODULE %s FINISHED: Job%d used %s.',...
                                moduleName,JobID,sec2dts(etime(dtvf,dtvs)));
                            aas_log(obj.aap,false,msg,obj.aap.gui_controls.colours.completed);
                            
                            % Also save to file with module name attached!
                            fid = fopen(fullfile(aaworker.parmpath,'qsub','time_estimates.txt'), 'a');
                            fprintf(fid,'%s\n',msg);
                            fclose(fid);
                            
                            taskreported(end+1) = ftmind;
                        case 'error';
                            msg = sprintf('Job%d had an error: %s\n',JobID,Task.ErrorMessage);
                            for e = 1:numel(Task.Error.stack)
                                % Stop tracking to internal
                                if strfind(Task.Error.stack(e).file,'distcomp'), break, end
                                msg = [msg sprintf('in %s (line %d)\n', ...
                                    Task.Error.stack(e).file, Task.Error.stack(e).line)];
                            end
                            % If there is an error, it is fatal...
                            aas_log(obj.aap,true,msg,obj.aap.gui_controls.colours.error)
                            
                            taskreported(end+1) = ftmind;
                    end
                end
                
                obj.taskstomonitor(taskreported) = [];
                
                % Loop if we are still waiting for jobs to finish...
                if waitforalljobs == 1;
                    if isempty(obj.taskstomonitor)
                        waitforalljobs = 0;
                    end
                end                
            end
        end
        
        function [obj]=qsub_q_job(obj,job)
            global aaworker
            
            % Let's store all our qsub thingies in one particular directory
            qsubpath=fullfile(aaworker.parmpath,'qsub');
            if (exist(qsubpath,'dir')==0)
                mkdir(qsubpath);
            end
            cd(qsubpath);
            
            % Submit the job using qsubfeval
            %             % Check how much memory and time we should assign to the job
            % Not in use [TA]
            %             try
            %                 memReq = obj.aap.tasksettings.(job.stagename).qsub.memoryBase * ... % module specific multiplier
            %                     obj.aap.options.qsub.memoryMult * ... % study specific multiplier
            %                     (1024^3); % GB
            %                 timReq = obj.aap.tasksettings.(job.stagename).qsub.timeBase * ... % module specific multiplier
            %                     obj.aap.options.qsub.timeMult * ... % study specific multiplier
            %                     60*60; % Hours
            %             catch
            %                 aas_log(obj.aap,false,...
            %                     sprintf('%s does not contain information about qsub time/memory requirements!', job.stagename), ...
            %                     [1 0 0])
            %                 memReq = ... % No module specific multiplier
            %                     obj.aap.options.qsub.memoryMult * ... % study specific multiplier
            %                     (1024^3); % GB
            %                 timReq = ... % No module specific multiplier
            %                     obj.aap.options.qsub.timeMult * ... % study specific multiplier
            %                     60*60; % Hours
            %             end
            
            % Submit job
            if ~isempty(obj.scheduler)
                J = createJob(obj.scheduler);
                cj = @aa_doprocessing_onetask;
                nrtn = 0;
                inparg = {obj.aap,job.task,job.k,job.indices};
                
                % [RT 2013-09-04 and 2013-11-11; TA 2013-11-14] Make workers self-sufficient by passing
                % them the aa paths. Users don't need to remember to update
                % their own default paths (e.g. for a new aa version)
                % AA
                mfp=textscan(mfilename('fullpath'),'%s','delimiter',filesep); mfp = mfp{1};
                mfpi=find(strcmp('aa_engine',mfp));
                aapath=textscan(genpath([filesep fullfile(mfp{1:mfpi-1})]),'%s','delimiter',':'); aapath = aapath{1};
                % SPM
                aapath{end+1}=fileparts(which('spm')); % SPM dir
                p = textscan(path,'%s','delimiter',':'); p = p{1};
                p_ind = cell_index(p,aapath{end}); % SPM-related dir
                for ip = p_ind
                    aapath{end+1} = p{ip};
                end
                if isfield(obj.aap.directory_conventions,'spmtoolsdir') && ~isempty(obj.aap.directory_conventions.spmtoolsdir)
                    SPMTools = textscan(obj.aap.directory_conventions.spmtoolsdir,'%s','delimiter', ':');
                    SPMTools = SPMTools{1};
                    for p = SPMTools'
                        if exist(p{1},'dir'), aapath{end+1}=p{1};end        
                    end
                end   
                % MNE
                if isfield(obj.aap.directory_conventions,'mnedir') && ~isempty(obj.aap.directory_conventions.mnedir)
                    if exist(fullfile(obj.aap.directory_conventions.mnedir,'matlab'),'dir')
                        aapath{end+1}=fullfile(obj.aap.directory_conventions.mnedir,'matlab','toolbox');
                        aapath{end+1}=fullfile(obj.aap.directory_conventions.mnedir,'matlab','examples');
                    end
                end 
                aapath=aapath(strcmp('',aapath)==0);
                
                if isprop(J,'AdditionalPaths')
                    J.AdditionalPaths = aapath;
                elseif isprop(J,'PathDependencies')
                    J.PathDependencies = aapath;
                end
                
                createTask(J,cj,nrtn,inparg);
                J.submit;
                %                 % State what the assigned number of hours and GB is...
                % Not in use [TA]
                %                 fprintf('Job %s, assigned %0.4f hours. and %0.9f GB\n\n', ...
                %                     job.stagename, timReq./(60*60), memReq./(1024^3))
                
                % And monitor for files with the job output
                obj.taskstomonitor(end+1)=J.ID;
            else
                aa_doprocessing_onetask(obj.aap,job.task,job.k,job.indices);
            end
        end
    end
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%% UTILS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

function dtv = dts2dtv(dts)
s = textscan(dts,'%s'); s = s{1}; s(5) = [];
s = strcat(s,{' ',' ',' ',' ',' '}'); s = [s{:}]; s = s(1:end-1);
dtformat = 'ddd mmm dd HH:MM:SS yyyy';
dtv = datevec(s,dtformat);
end

function dts = sec2dts(dt)
dt_str = {'s','m','h'};
dt_div = [60 60 24]; 

dts = '';
for i = 1:numel(dt_str)
    dts = [' ' num2str(mod(dt,dt_div(i))) dt_str{i} dts]; dt = floor(dt/dt_div(i));
    if ~dt, break, end
end
if dt
    dts = [num2str(dt) 'd' dts]; 
else
    dts = dts(2:end);
end
end