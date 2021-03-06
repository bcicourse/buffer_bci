run ../../utilities/initPaths;
  
buffhost='localhost';buffport=1972;
% wait for the buffer to return valid header information
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

% set the real-time-clock to use
initgetwTime;
initsleepSec;

% get cap layout info
di = addPosInfo(hdr.channel_names,'1010'); % get 3d-coords
ch_pos=cat(2,di.extra.pos2d); ch_names=di.vals; iseeg=[di.extra.iseeg]; % extract pos and channels names

trlen_samp = 50; % #samples per epoch
nSymbols = 2;
erp      = zeros(sum(iseeg),trlen_samp,nSymbols);
nTarget  = zeros(nSymbols,1);

% make the figure window
clf;
hdls=image3d(erp,1,'plotPos',ch_pos,'xlabel','ch','Xvals',ch_names,'zlabel','class','disptype','plot','ticklabs','sw');

state=[];
endTest=false; 
while( ~endTest )
  % block until we've got new events *and* data to process
  [data,devents,state]=buffer_waitData([],[],state,'startSet',{'stimulus.epoch'},'trlen_samp',trlen_samp,'exitSet',{'data' 'stimulus.sequences' 'end'});

  for ei=numel(devents):-1:1; % process in reverse order = temporal order
    event=devents(ei);
    % check for exit events
    if( isequal('stimulus.sequences',event.type) && isequal('end',event.value) ) % end event
      endTest=true; 
      fprintf('Discarding all subsequent events: exit\n');
      break;
    end;

    % update the ERPs info
    class=devents(ei).value;
    erp(:,:,class) = (erp(:,:,class)*nTarget(class) + data.buf(iseeg,:))/(nTarget(class)+1);
    nTarget(class) = nTarget(class)+1;        
    
    % update the ERP plot
    hdls=image3d(erp,1,'handles',hdls,'xlabel','ch','Xvals',ch_names,'zlabel','class','disptype','plot','ticklabs','sw');
    drawnow;    
  end % for ei=1:numel(devents)
end