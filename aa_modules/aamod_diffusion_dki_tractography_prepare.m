function [aap resp]=aamod_diffusion_dki_tractography_prepare(aap,task,subjind,diffsessind)
resp='';

switch task
    case 'report'
    case 'doit'
        %% Fetch inputs
        % Get nii filenames from stream
        DT=nifti_read(aas_getfiles_bystream(aap,'diffusion_session',[subjind diffsessind],'dki_DT'));
        KT=nifti_read(aas_getfiles_bystream(aap,'diffusion_session',[subjind diffsessind],'dki_KT'));
        betmask=cellstr(aas_getfiles_bystream(aap,'diffusion_session',[subjind diffsessind],'BETmask'));
        
        % Find which line of betmask contains the brain mask
        betmask=betmask{cellfun(@(x) ~isempty(regexp(x,'bet_.*nodif_brain_mask', 'once')), betmask)};

        alfa = aap.tasklist.currenttask.settings.alfa;
        
        %% Calculate direction field
        [dki.NM, dki.DirM, dki.DirF] = fun_extract_directions_from_DKI_ODF(DT,KT,nifti_read(betmask),alfa);
        
        %% Now describe outputs
        V = spm_vol(betmask); V.dt = spm_type('float32');
        sesspath = aas_getpath_bydomain(aap,'diffusion_session',[subjind,diffsessind]);

        outstreams=aas_getstreams(aap,'output');        
        for outind=1:length(outstreams)
            metric = strrep(outstreams{outind},'dki_','');
            if ~exist(metric,'var')
                aas_log(aap,false,sprintf('Metric %s for stream %s not exist!',metric,outstreams{outind}));
                continue; 
            end
            Y = dki.(metric);  
            nifti_write(fullfile(sesspath,[outstreams{outind} '.nii']),Y,outstreams{outind},V);
            aap=aas_desc_outputs(aap,'diffusion_session',[subjind,diffsessind],outstreams{outind},[outstreams{outind} '.nii']);
        end
        
end
end



