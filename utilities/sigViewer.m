function []=sigViewer(buffhost,buffport,varargin);
% simple eegviewer function
%
% eegViewer(buffhost,buffport,varargin)
%
% Inputs:
%  buffhost -- host name where the buffer is
%  buffport -- port to connect to
% Options:
%  endType -- event type which means stop viewing eeg   ('end.training')
%  trlen_ms/trlen_samp -- amount of data to plot for each channel (5000ms)
%  updateFreq -- [single] frequency to re-draw the display           (4)
%  detrend    -- [bool]  detrend the data before plotting            (1)
%  fftfilter  -- [4x1] spectral filter to apply to the data before plotting ([.1 .3 45 47])
%  downsample -- [single] frequency to downsample to before drawing display (128)
%  spatfilt   -- 'str' name of type of spatial filtering to do to the data   ('car')
%  capFile    -- [str] capFile name to get the electrode positions from      ('1010')
%  overridechnms -- [bool] flag if we use the channel names from the capFile rather than the buffer (0)
%  welch_width_ms -- [single] size in time of the welch window               (500ms) 
%                      -> defines the frequency resolution for the frequency view of the data.   
%  freqbands  -- [2x1] frequency bands to display in the freq-domain plot    (opts.fftfilter)
%  noisebands -- [2x1] frequency bands to display for the 50 Hz noise plot   ([45 47 53 55])
%  sigprocoptsgui -- [bool] show the on-line option changing gui             (1)
wb=which('buffer'); if ( isempty(wb) || isempty(strfind('dataAcq',wb)) ) run('../utilities/initPaths.m'); end;
opts=struct('endType','end.training','verb',1,'trlen_ms',5000,'trlen_samp',[],'updateFreq',4,'detrend',1,'fftfilter',[.1 .3 45 47],'freqbands',[],'downsample',128,'spatfilt','car','badchrm',0,'badchthresh',3,'capFile',[],'overridechnms',0,'welch_width_ms',500,'noisebands',[45 47 53 55],'noiseBins',[0 1.75],'timeOut_ms',1000,'spectBaseline',1,'sigProcOptsGui',1,'dataStd',2.5,'covhalflife',20);
opts=parseOpts(opts,varargin);
if ( nargin<1 || isempty(buffhost) ) buffhost='localhost'; end;
if ( nargin<2 || isempty(buffport) ) buffport=1972; end;
if ( isempty(opts.freqbands) && ~isempty(opts.fftfilter) ) opts.freqbands=opts.fftfilter; end;

% get channel info for plotting
hdr=[];
while ( isempty(hdr) || ~isstruct(hdr) || (hdr.nchans==0) ) % wait for the buffer to contain valid data
  try 
    hdr=buffer('get_hdr',[],buffhost,buffport); 
  catch
    hdr=[];
    fprintf('Invalid header info... waiting.\n');
  end;
  pause(1);
end;
% extract channel info from hdr
ch_names=hdr.channel_names; ch_pos=[]; iseeg=true(numel(ch_names),1);
% get capFile info for positions
capFile=opts.capFile; overridechnms=opts.overridechnms; 
if(isempty(opts.capFile)) 
  [fn,pth]=uigetfile('../utilities/*.txt','Pick cap-file'); drawnow;
  if ( ~isequal(fn,0) ) capFile=fullfile(pth,fn); end;
  %if ( isequal(fn,0) || isequal(pth,0) ) capFile='1010.txt'; end; % 1010 default if not selected
end
if ( ~isempty(strfind(capFile,'1010.txt')) ) overridechnms=0; else overridechnms=1; end; % force default override
if ( ~isempty(capFile) ) 
  di = addPosInfo(ch_names,capFile,overridechnms); % get 3d-coords
  ch_pos=cat(2,di.extra.pos2d); % extract pos and channels names
  ch_pos3d=cat(2,di.extra.pos3d);
  ch_names=di.vals; 
  iseeg=[di.extra.iseeg];
  if ( ~any(iseeg) || strcmp(capFile,'showAll') ) % fall back on showing all data
    warning('Capfile didnt match any data channels -- no EEG?');
    ch_names=hdr.channel_names;
    ch_pos=[];
    iseeg=true(numel(ch_names),1);
  end
end

% add number prefix to ch-names for display
for ci=1:numel(ch_names); ch_names{ci} = sprintf('%d %s',ci,ch_names{ci}); end;

if ( isfield(hdr,'fSample') ) fs=hdr.fSample; else fs=hdr.fsample; end;
trlen_samp=opts.trlen_samp;
if ( isempty(trlen_samp) && ~isempty(opts.trlen_ms) ) trlen_samp=round(opts.trlen_ms*fs/1000); end;
update_samp=ceil(fs/opts.updateFreq);
trlen_samp=ceil(trlen_samp/update_samp)*update_samp;
fprintf('tr_samp = %d update_samp = %d\n',trlen_samp,update_samp);
blkIdx = trlen_samp-update_samp; % index for where new data gets inserted
if ( isempty(opts.downsample) || opts.downsample>fs ) 
    times=(-trlen_samp+1:0)./fs;
else
    times=(-ceil((trlen_samp+1)*opts.downsample/fs):0)/opts.downsample;
end
freqs=0:1000/opts.welch_width_ms:fs/2;
freqIdx =getfreqIdx(freqs,opts.freqbands);
noiseIdx=getfreqIdx(freqs,opts.noisebands);

% make the spectral filter
filt=[]; if ( ~isempty(opts.freqbands)) filt=mkFilter(trlen_samp/2,opts.freqbands,fs/trlen_samp);end
outsz=[trlen_samp trlen_samp];if(~isempty(opts.downsample)) outsz(2)=min(outsz(2),round(trlen_samp*opts.downsample/fs)); end;
  
% recording the ERP data
rawdat    = zeros(sum(iseeg),outsz(1));
ppdat     = zeros(sum(iseeg),outsz(2));
% and the spectrogram version
[ppspect,start_samp,freqs]=spectrogram(rawdat,2,'width_ms',opts.welch_width_ms,'fs',hdr.fsample);
ppspect=ppspect(:,freqIdx(1):freqIdx(2),:); % subset to freq range of interest
start_s=-start_samp(end:-1:1)/hdr.fsample;
% and the data summary statistics
chCov     = zeros(sum(iseeg),sum(iseeg));
covAlpha  = exp(log(.5)./opts.covhalflife);
isbadch   = false(sum(iseeg),1);

% pre-compute the SLAP spatial filter
slapfilt=[];
if ( ~isempty(ch_pos) )       
  slapfilt=sphericalSplineInterpolate(ch_pos3d(:,iseeg),ch_pos3d(:,iseeg),[],[],'slap');%pre-compute the SLAP filter we'll use
else
  warning('Cant compute SLAP without channel positions!'); 
end

% make the figure window
if ( exist('OCTAVE_VERSION','builtin') ) % use best octave specific graphics facility
  if ( ~isempty(strmatch('qthandles',available_graphics_toolkits())) )
    graphics_toolkit('qthandles'); % use fast rendering library
  elseif ( ~isempty(strmatch('fltk',available_graphics_toolkits())) )
    graphics_toolkit('fltk'); % use fast rendering library
  end
end
clf;
fig=gcf;
set(fig,'Name','Sig-Viewer : t=time, f=freq, p=50Hz power, s=spectrogram, q,close window=quit.','menubar','none','toolbar','none','doublebuffer','on');
axes('position',[0 0 1 1]); topohead();set(gca,'visible','off','nextplot','add');
plotPos=ch_pos; if ( ~isempty(plotPos) ) plotPos=plotPos(:,iseeg); end;
hdls=image3d(ppspect,1,'plotPos',plotPos,'Xvals',ch_names,'yvals',freqs(freqIdx(1):freqIdx(2)),'ylabel','freq (hz)','zvals',start_s,'zlabel','time (s)','disptype','imaget','colorbar',1,'ticklabs','sw','legend',0,'plotPosOpts.plotsposition',[.05 .08 .91 .85]);
cbarhdl=[]; 
if ( strcmpi(get(hdls(end),'Tag'),'colorbar') ) 
  cbarhdl=hdls(end); hdls(end)=[]; cbarpos=get(cbarhdl,'outerposition');
  set(findobj(cbarhdl),'visible','off'); % store and make invisible
end;
if ( ~exist('OCTAVE_VERSION','builtin') ) % in octave have to manually convert arrays..
  zoomplots;
end
% install listener for key-press mode change
set(fig,'keypressfcn',@(src,ev) set(src,'userdata',char(ev.Character(:)))); 
set(fig,'userdata',[]);
drawnow; % make sure the figure is visible

% make popup menu for selection of TD/FD
modehdl=[]; vistype=0; curvistype='time';
if ( ~exist('OCTAVE_VERSION','builtin') ) % in octave have to manually convert arrays..
  modehdl=uicontrol(fig,'Style','popup','units','normalized','position',[.8 .9 .2 .1],'String','Time|Frequency|50Hz|Spect');
  set(modehdl,'value',1);
end
colormap trafficlight; % red-green colormap for 50Hz pow

% extract the lines so we can directly update them.
datlim=[inf -inf];
for hi=1:numel(hdls); set(hdls(hi),'nextplot','add'); end; % all plots hold on.  Needed for OCTAVE
for hi=1:size(ppdat,1); 
  cldhdls = get(hdls(hi),'children');
  img_hdls(hi)=findobj(cldhdls,'type','image');%set(line_hdls(hi),'linewidth',1);
  %img_hdls(hi)=line(hdls(hi),'xdata',[1 1],'ydata',[1 1],'cdata',1,'CDataMapping','scaled','parent',hdls(hi),'visible','off');
  line_hdls(hi)=line([1 1],[1 1],'parent',hdls(hi),'visible','on','linewidth',1);
  set(hdls(hi),'ydir','normal'); % undo the dir reset by image
  % set the drawing oder so the title is always on top
  if ( ~exist('OCTAVE_VERSION','builtin') ) % in octave have to manually convert arrays..  
    set(hdls(hi),'children',[get(hdls(hi),'title');get(hdls(hi),'children')]);
  end
  datlimi=get(hdls(hi),'ylim');datlim(1)=min(datlim(1),datlimi(1)); datlim(2)=max(datlim(2),datlimi(2));
end;

ppopts.badchrm=opts.badchrm;
ppopts.preproctype='none';if(opts.detrend)ppopts.preproctype='detrend'; end;
ppopts.spatfilttype=opts.spatfilt;
ppopts.freqbands=opts.freqbands;
optsFighandles=[];
if ( isequal(opts.sigProcOptsGui,1) )
  optsFigh=sigProcOptsFig();
  optsFighandles=guihandles(optsFigh);
  set(optsFighandles.lowcutoff,'string',sprintf('%g',ppopts.freqbands(1)));
  set(optsFighandles.highcutoff,'string',sprintf('%g',ppopts.freqbands(end)));  
  for h=get(optsFighandles.spatfilt,'children')'; 
    if ( strcmpi(get(h,'string'),ppopts.spatfilttype) ) set(h,'value',1); break;end; 
  end;
  for h=get(optsFighandles.preproc,'children')'; 
    if ( strcmpi(get(h,'string'),ppopts.preproctype) ) set(h,'value',1); break;end; 
  end;
  set(optsFighandles.badchrm,'value',ppopts.badchrm);
  ppopts=getSigProcOpts(optsFighandles);
end

endTraining=false; state=[];
cursamp=hdr.nSamples;
while ( ~endTraining )  

  %------------------------------------------------------------------------
  % wait for new data, 
  % N.B. wait_data returns based on Number of samples, get_data uses sample index = #samples-1
  status=buffer('wait_dat',[cursamp+update_samp+1 inf opts.timeOut_ms],buffhost,buffport);
  if( status.nSamples < cursamp+update_samp )
    fprintf('Buffer stall detected...\n');
    pause(1);
    cursamp=status.nSamples;
    if ( ~ishandle(fig) ) break; else continue; end;
  elseif ( status.nSamples > cursamp+update_samp*2 ) % missed a whole update window
    cursamp=status.nSamples - update_samp-1; % jump to the current time
  end;
  dat   =buffer('get_dat',[cursamp cursamp+update_samp-1],buffhost,buffport);
  cursamp = cursamp+update_samp;
  
  % shift and insert into the data buffer
  rawdat(:,1:blkIdx)=rawdat(:,update_samp+1:end);
  rawdat(:,blkIdx+1:end)=dat.buf(iseeg,:);

  if ( opts.verb>0 ) fprintf('.'); end;
  if ( ~ishandle(fig) ) break; end;

  %------------------------------------------------------------------------
  % Get updated user input
  % switch visualization mode if wanted
  modekey=[]; if ( ~isempty(modehdl) ) modekey=get(modehdl,'value'); end;
  if ( ~isempty(get(fig,'userdata')) ) modekey=get(fig,'userdata'); end; % key-overrides drop-down
  if ( ~isempty(modekey) )
    switch ( modekey(1) );
     case {1,'t'}; modekey=1;curvistype='time';
     case {2,'f'}; modekey=2;curvistype='freq';
     case {3,'p'}; modekey=3;curvistype='power';
     case {4,'s'}; modekey=4;curvistype='spect';
     case 'q';     break;
     otherwise;    modekey=1;
    end;
    set(fig,'userdata',[]);
    if ( ~isempty(modehdl) ) set(modehdl,'value',modekey); end;
  end
  % get updated sig-proc parameters if needed
  if ( ~isempty(optsFighandles) && ishandle(optsFighandles.figure1) )
    [ppopts,damage]=getSigProcOpts(optsFighandles,ppopts);
    % compute updated spectral filter information, if needed
    if ( damage(4) ) % freq range changed
      filt=[];
      if ( ~isempty(ppopts.freqbands) ) % filter bands given
        filt=mkFilter(trlen_samp/2,ppopts.freqbands,fs/trlen_samp); 
      end
      freqIdx =getfreqIdx(freqs,ppopts.freqbands);
    end
  end

  %------------------------------------------------------------------------
  % pre-process the data
  ppdat = rawdat;
  switch(lower(ppopts.preproctype));
   case 'none';   
   case 'center'; ppdat=repop(ppdat,'-',mean(ppdat,2));
   case 'detrend';ppdat=detrend(ppdat,2);
   otherwise; warning(sprintf('Unrecognised pre-proc type: %s',lower(ppopts.preproctype)));
  end

  % track the covariance properties of the data
  chCov = chCov*covAlpha + (1-covAlpha)*(ppdat(:,blkIdx+1:end)*ppdat(:,blkIdx+1:end)'./(size(ppdat,2)-blkIdx));
  
  if ( ~strcmp(curvistype,'power') ) % BODGE: 50Hz power doesn't do any spatial filtering, or bad-channel removal

    % bad channel removal
    if ( ppopts.badchrm>0 || strcmp(ppopts.badchrm,'1') )
      chPow = chCov(1:size(chCov,1)+1:end);
      fprintf('%s < %g\n',sprintf('%g ',chPow),mean(chPow)+opts.badchthresh*std(chPow));
      for i=1:3;
        isbadch = chPow>(mean(chPow(~isbadch))+opts.badchthresh*std(chPow(~isbadch))) | chPow<eps;
      end
      ppdat(isbadch,:)=0; % zero out the bad channels
    else
      isbadch(:)=false;
    end
    
    % spatial filter
    switch(lower(ppopts.spatfilttype))
     case 'none';
     case 'car';    ppdat(~isbadch,:,:)=repop(ppdat(~isbadch,:,:),'-',mean(ppdat(~isbadch,:,:),1));
     case 'slap';   
      if ( ~isempty(slapfilt) ) % only use and update from the good channels
        ppdat(~isbadch,:,:)=tprod(ppdat(~isbadch,:,:),[-1 2 3],slapfilt(~isbadch,~isbadch),[-1 1]); 
      end;
     case 'whiten'; % use the current data-cov to estimate the whitener
      [U,s]=eig(chCov(~isbadch,~isbadch)); s=diag(s); % eig-decomp
      si=s>0 & ~isinf(s) & ~isnan(s);
      W    = U(:,si) * diag(1./s(si)) * U(:,si)';
      ppdat(~isbadch,:,:)=tprod(ppdat(~isbadch,:,:),[-1 2 3],W,[-1 1]);      
     otherwise; warning(sprintf('Unrecognised spatial filter type : %s',ppopts.spatfilttype));
    end
  end
  
  switch (curvistype) 
    
   case 'time'; % time-domain, spectral filter
    if ( ~isempty(filt) )      ppdat=fftfilter(ppdat,filt,outsz,2);  % N.B. downsample at same time
    elseif ( ~isempty(outsz) ) ppdat=subsample(ppdat,outsz(2),2); % manual downsample
    end
    
   case 'freq'; % freq-domain
    ppdat = welchpsd(ppdat,2,'width_ms',opts.welch_width_ms,'fs',hdr.fsample,'aveType','db');
    ppdat = ppdat(:,freqIdx(1):freqIdx(2));
    
   case 'power'; % 50Hz power, N.B. on the last 2s data only!
    ppdat = welchpsd(ppdat(:,find(times>-2,1):end),2,'width_ms',opts.welch_width_ms,'fs',hdr.fsample,'aveType','amp');
    ppdat = mean(ppdat(:,noiseIdx(1):noiseIdx(2)),2); % ave power in this range
    ppdat = sqrt(ppdat); % BODGE: extra transformation to squeeze the large power values...
    
   case 'spect'; % spectrogram
    ppdat = spectrogram(ppdat,2,'width_ms',opts.welch_width_ms,'fs',hdr.fsample);
    ppdat = ppdat(:,freqIdx(1):freqIdx(2),:);    
    % subtract the 'common-average' spectrum
    if ( opts.spectBaseline ) ppdat=repop(ppdat,'-',mean(mean(ppdat,3),1)); end
  end
  
  % compute useful range of data to show
  % add some artifact robustness, data-lim is mean+3std-dev
  datstats=[mean(ppdat(:)) std(ppdat(:))];
  datrange=[max(min(ppdat(:)),datstats(1)-opts.dataStd*datstats(2)) min(datstats(1)+opts.dataStd*datstats(2),max(ppdat(:)))];

  %---------------------------------------------------------------------------------
  % Do visualisation mode switching work
  if ( ~isequal(vistype,curvistype) || any(damage(4)) ) % reset the axes
    datlim=datrange;
    if ( datlim(1)>=datlim(2) || any(isnan(datlim)) ) datlim=[-1 1]; end;
    switch ( vistype ) % do pre-work dependent on current mode
     case 'power'; % 50hz power
      for hi=1:size(ppdat,1); % turn the tickmarks and label visible again
        if ( ~isempty(get(hdls(hi),'Xlabel')) && isequal(get(get(hdls(hi),'xlabel'),'visible'),'on') ) 
          set(hdls(hi),'xticklabelmode','auto','yticklabelmode','auto');
        end
        xlabel(hdls(hi),'time (s)');
        ylabel('');
      end        
      if ( ~isempty(cbarhdl) ) set(findobj(cbarhdl),'visible','off'); end
     case 'spect'; if ( ~isempty(cbarhdl) ) set(findobj(cbarhdl),'visible','off'); end
    end
    
    % compute the current vis-types plot
    switch ( curvistype )       
     case 'time'; % time-domain
      for hi=1:size(ppdat,1);
        xlabel(hdls(hi),'time (s)');
        ylabel(hdls(hi),'');
        set(hdls(hi),'xlim',[times(1) times(size(ppdat,2))],'ylim',datlim);            
      end
      set(img_hdls,'visible','off'); % make the colors invisible        
      set(line_hdls,'xdata',times(1:size(ppdat,2)),'visible','on');
      
     case 'freq'; % frequency domain
      for hi=1:size(ppdat,1);
        xlabel(hdls(hi),'freq(hz)');
        ylabel(hdls(hi),'');
        set(hdls(hi),'xlim',freqs([freqIdx(1) freqIdx(2)]),'ylim',datlim);
      end
      set(img_hdls,'visible','off'); % make the colors invisible        
      set(line_hdls,'xdata',freqs(freqIdx(1):freqIdx(2)),'visible','on');
      
     case 'power'; % 50Hz Power
                   % all the same axes
      datlim=[opts.noiseBins(1) opts.noiseBins(end)];
      set(hdls,'xlim',[.5 1.5],'ylim',[.5 1.5],'clim',datlim);
      set(line_hdls,'visible','off');
      set(img_hdls,'cdata',1,'xdata',[1 1],'ydata',[1 1],'visible','on'); % make the color images visible
      for hi=1:size(ppdat,1); % make the tickmarks and axes label invisible
        if ( ~isempty(get(hdls(hi),'Xlabel')) && isequal(get(get(hdls(hi),'xlabel'),'visible'),'on') ) 
          set(hdls(hi),'xticklabel',[],'yticklabel',[]);
        end
        xlabel(hdls(hi),'50Hz Power');
        ylabel(hdls(hi),'');
      end
      if ( ~isempty(cbarhdl) ) 
        set(cbarhdl,'outerposition',cbarpos); % ARGH! octave moves the cbar if axes are changed!
        set(findobj(cbarhdl),'visible','on');
        set(get(cbarhdl,'children'),'ydata',datlim);set(cbarhdl,'ylim',datlim); 
      end;
      
     case 'spect'; % spectrogram
      set(hdls,'xlim',start_s([1 end]),'ylim',freqs([freqIdx(1) freqIdx(2)]),'clim',datlim); % all the same axes
      set(line_hdls,'visible','off');
      % make the color images visible, in the right place with the right axes positions
      set(img_hdls,'xdata',start_s([1 end]),'ydata',freqs([freqIdx(1) freqIdx(2)]),'visible','on');      
      for hi=1:numel(hdls); xlabel(hdls(hi),'time (s)'); ylabel(hdls(hi),'freq (hz)');end;
      if ( ~isempty(cbarhdl) ) 
        set(findobj(cbarhdl),'visible','on'); 
        set(get(cbarhdl,'children'),'ydata',datlim);set(cbarhdl,'ylim',datlim); 
        set(cbarhdl,'outerposition',cbarpos); 
      end;
    
    end
    vistype=curvistype;
  else % adapt the axes to the data
    if ( ~isequal(curvistype,'power') )
      if ( datrange(1)<datlim(1)-diff(datlim)*.2 || datrange(1)>datlim(1)+diff(datlim)*.2 || ...
           datrange(2)>datlim(2)+diff(datlim)*.2 || datrange(2)<datlim(2)-diff(datlim)*.2 )
        if ( isequal(datrange,[0 0]) ) 
          %fprintf('Warning: Clims are equal -- reset to clim+/- .5');
          datrange=.5*[-1 1]; 
        elseif ( datrange(1)==datrange(2) ) 
          datrange=datrange(1)+.5*[-1 1];
        end;         
        if ( isequal(curvistype,'spect') ) % spectrogram, datalim is color range
          datlim=datrange; set(hdls(1:size(ppdat,1)),'clim',datlim);
          % update the colorbar info
          if ( ~isempty(cbarhdl) ) set(get(cbarhdl,'children'),'ydata',datlim);set(cbarhdl,'ylim',datlim); end;
        else % lines - datalim is y-range
          datlim=datrange; set(hdls(1:size(ppdat,1)),'ylim',datlim);
        end
      end
    end
  end
  
  % update the plot
  switch ( curvistype ) 
    
   case {'time','freq'}; % td/fd -- just update the line info
    for hi=1:size(ppdat,1);
      set(line_hdls(hi),'ydata',ppdat(hi,:));
    end
    
   case {'power','spect'}; % 50Hz/spectrogram -- update the image data
    % map from raw power into the colormap we're using, not needed as we use the auto-scaling function
    %ppdat=max(opts.noiseBins(1),min(ppdat,opts.noiseBins(end)))./(opts.noiseBins(end)-opts.noiseBins(1))*size(colormap,1);
    for hi=1:size(ppdat,1);
      set(img_hdls(hi),'cdata',shiftdim(ppdat(hi,:,:)));
    end
  end
  drawnow;
end
% close the options figure as well
if ( exist('optsFigh') && ishandle(optsFigh) ) close(optsFigh); end;
return;

function freqIdx=getfreqIdx(freqs,freqbands)
if ( nargin<1 || isempty(freqbands) ) freqIdx=[1 numel(freqs)]; return; end;
[ans,freqIdx(1)]=min(abs(freqs-max(freqs(1),freqbands(1)))); 
[ans,freqIdx(2)]=min(abs(freqs-min(freqs(end),freqbands(end))));

function [sigprocopts,damage]=getSigProcOpts(optsFighandles,oldopts)
% get the current options from the sig-proc-opts figure
sigprocopts.badchrm=get(optsFighandles.badchrm,'value');
sigprocopts.spatfilttype=get(get(optsFighandles.spatfilt,'SelectedObject'),'String');
sigprocopts.preproctype=get(get(optsFighandles.preproc,'SelectedObject'),'String');
sigprocopts.freqbands=[real(str2num(get(optsFighandles.lowcutoff,'string'))) ...
                    real(str2num(get(optsFighandles.highcutoff,'string')))];  
if ( numel(sigprocopts.freqbands)>4 ) sigprocopts.freqbands=sigprocopts.freqbands(1:min(end,4));
elseif ( numel(sigprocopts.freqbands)<2 ) sigprocopts.freqbands=[];
end;
damage=false(4,1);
if( nargout>1 && nargin>1) 
  if ( isstruct(oldopts) )
    damage(1)= ~isequal(oldopts.badchrm,sigprocopts.badchrm);
    damage(2)= ~isequal(oldopts.spatfilttype,sigprocopts.spatfilttype);
    damage(3)= ~isequal(oldopts.preproctype,sigprocopts.preproctype);
    damage(4)= ~isequal(oldopts.freqbands,sigprocopts.freqbands);
  end
end
%-----------------------
function testCase();
% start the buffer proxy
% dataAcq/startSignalProxy
sigViewer();

