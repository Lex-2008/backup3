$=(x)=>document.querySelector(x);

api=(params, returnBlob)=>{
	var url=params;
	return fetch(`/cgi-bin/api.sh?${pass}|${params}`).then(a=>{
		if(a.status==403){
			// ask for a password
			if(pass=prompt('[username] password',pass)){
				// retry with a new password
				return api(url);
			} else {
				// abort
				Promise.reject('bad pass');
			}
		} else if(returnBlob) {
			return a.blob();
		} else {
			return a.text();
		}
	});
}

backups=[];
timeline=[];
pass='';
path='';
time='';
file='';
file_time='';
dirtree={};

// add dir to dirtree
addDir=(dirname, created, deleted)=>{
	var recurse=false;
	if(dirtree[dirname]){
		if(created<dirtree[dirname].created) {
			dirtree[dirname].created=created;
			recurse=true;
		}
		if(deleted>dirtree[dirname].deleted){
			dirtree[dirname].deleted=deleted;
			recurse=true;
		}
	} else {
		dirtree[dirname]={
			created:created,
			deleted:deleted,
			children:{},
		}
		recurse=true;
	}
	// var shortname=dirname.match('[^/]*$')[0];
	var shortname=dirname.slice(dirname.lastIndexOf('/')+1);
	var parent=dirname.slice(0,-shortname.length-1);
	if(parent){
		if(recurse)
			addDir(parent,created,deleted);
		dirtree[parent].children[shortname]=1;
	}
}

// fill list of backups (in top-left corner) and backups global var
fillBackups=()=>{
	pass='';
	api('init').then(a=>{
		backups=a.trim().split('\n').filter(a=>a.endsWith('/')).map(a=>a.slice(0,-1));
		$('.backups select').innerHTML=backups.map((a)=>`<option>${a}</option>`).join('');
		$('.backups select').onchange=function(){
			location.hash='#'+this.value;
		};
		window.onhashchange();
	});
};

window.onhashchange=()=>{
	// #dir|dir-date|file|file-date
	var loc=decodeURIComponent(location.hash.slice(1)).split('|');
	// First, check if dir exists in dirtree
	if(dirtree[loc[0]]){
		path=loc[0];
		// Now, check if time is valid
		var time_index=-1;
		if(loc.length>1){
			time_index=timeline.indexOf(loc[1]);
		}
		if(time_index!=-1){
			$('#q').value=time_index;
		} else {
			// Time is not valid - set latest
			time_index=$('#q').max;
			$('#q').value=time_index;
		}
		time=timeline[time_index];
		file='';
		if(loc.length>2){
			file=loc[2];
		}
		file_time='';
		if(loc.length>3){
			file_time=loc[3];
		}
		render();
	} else {
		// Dir not found.
		// It means that location refers to another backup
		// First, find which backup location.hash refers to
		var backup=backups.filter(a=>loc[0].startsWith(a)).sort((a,b)=>(a.length-b.length)).pop();
		if(backup){
			// Second, find if current dirtree refers to the same backup as location.hash does
			// (we've just found it on the previous step)
			if(!dirtree[backup]) {
				// Nope, dirtree is either empty or refers to a different backup.
				// in this case we fill it anew with the new backup
				// (fillTimeline will call window.onhashchange again)
				fillTimeline(backup);
			} else {
				// Yes, dirtree refers to the same backup as location.hash.
				// It means that location.hash has a wrong dir.
				// It would be smart to count number of slashes in location.hash
				// in order to find path and preserve it, while replacing time with more current one,
				// but for now we just reset location.hash to a backup root.
				location.hash='#'+backup;
				// window.onhashchange();
			}
		} else {
			// None of backups was found in location.hash.
			// It means the link is very wrong.
			// Assuming list of backups is already loaded, go to a first backup
			location.hash='#'+backups[0];
			// window.onhashchange();
		}
	}
}

// fill timeline input (top right corner) and timeline global var
fillTimeline=(backup)=>{
	// reset pass
	pass='';
	api(`timeline|${backup}`).then(a=>{
		var data=a.split('\n').filter(a=>!!a);
		var idx1=data.indexOf('---');
		var idx2=data.indexOf('===');
		var idx3=data.indexOf('+++');
		var created=data.slice(0,idx1);
		var deleted=data.slice(idx1+1,idx2);
		var alltimes=created.concat(deleted).filter((x,i,a)=>a.indexOf(x)==i);
		var freqtimes=[];
		var ticks=[];
		data.slice(idx2+1,idx3).map(a=>a.split('|')).forEach(a=>{
			var e=a[1].match(/^([0-9]*)-([0-9]*)-([0-9]*) ([0-9]*):([0-9]*)$/);
			var d=e.map(a=>parseInt(a));
			var now=new Date();
			var now=new Date(Date.UTC(now.getFullYear(),now.getMonth(),now.getDate(), now.getHours(),now.getMinutes()));
			switch(a[0]){
				case '1':
					// add 1st of every month
					d[2]++;
					var day=new Date(Date.UTC(d[1],d[2]-1,1));
					ticks.push(day.toISOString().slice(0, 16).replace('T',' '));
					while(true){
						var day=new Date(Date.UTC(d[1],d[2]-1,1));
						if(day>now) break;
						freqtimes.push(day.toISOString().slice(0, 16).replace('T',' '));
						d[2]++;
					}
					break;
				case '5':
					// find nearest following Monday
					d[3]++;
					while(true){
						var day=new Date(Date.UTC(d[1],d[2]-1,d[3]));
						if(day.getDay()==1) break;
						d[3]++;
					}
					var day=new Date(Date.UTC(d[1],d[2]-1,d[3]));
					ticks.push(day.toISOString().slice(0, 16).replace('T',' '));
					while(true){
						// add every 7th day (Monday)
						var day=new Date(Date.UTC(d[1],d[2]-1,d[3]));
						if(day>now) break;
						freqtimes.push(day.toISOString().slice(0, 16).replace('T',' '));
						d[3]+=7;
					}
					break;
				case '30':
					d[3]++;
					var day=new Date(Date.UTC(d[1],d[2]-1,d[3]));
					ticks.push(day.toISOString().slice(0, 16).replace('T',' '));
					while(true){
						// add every day (midnight)
						var day=new Date(Date.UTC(d[1],d[2]-1,d[3]));
						if(day>now) break;
						freqtimes.push(day.toISOString().slice(0, 16).replace('T',' '));
						d[3]++;
					}
					break;
				case '720':
					d[4]++;
					var day=new Date(Date.UTC(d[1],d[2]-1,d[3], d[4]));
					ticks.push(day.toISOString().slice(0, 16).replace('T',' '));
					while(true){
						// add every hour
						var day=new Date(Date.UTC(d[1],d[2]-1,d[3], d[4]));
						if(day>now) break;
						freqtimes.push(day.toISOString().slice(0, 16).replace('T',' '));
						d[4]++;
					}
					break;
				default:
					d[5]+=5;
					var day=new Date(Date.UTC(d[1],d[2]-1,d[3], d[4],d[5]));
					ticks.push(day.toISOString().slice(0, 16).replace('T',' '));
					while(true){
						// add every 5 minutes
						var day=new Date(Date.UTC(d[1],d[2]-1,d[3], d[4],d[5]));
						if(day>now) break;
						freqtimes.push(day.toISOString().slice(0, 16).replace('T',' '));
						d[5]+=5;
					}
					break;
			} // switch
		});
		var changesCache={};
		var shouldBeAdded=(time,indx,array)=>{
			if(alltimes.indexOf(a)!=-1 || indx==0){
				return true;
			}
			var prev=array[indx-1];
			if(!changesCache[prev]){
				changesCache[prev]=alltimes.filter(a=>a<=prev).length;
			}
			changesCache[time]=alltimes.filter(a=>a<=time).length;
			return changesCache[time]>changesCache[prev];

		};
		timeline=freqtimes.filter((x,i,a)=>a.indexOf(x)==i).sort().filter(shouldBeAdded);
		ticks.push(timeline[timeline.length-1]);
		$('#marks').innerHTML=ticks.map(a=>timeline.indexOf(a)).filter(a=>a!=-1).map(a=>`<option value="${a}">`).join('\n');
		dirtree={};
		data.slice(idx3+1).forEach(a=>{
			a=a.split('|');
			addDir(a[0],a[1],a[2]);
		})
		$('.backups select').value=backup;
		$('#q').value=$('#q').max=timeline.length-1;
		$('#q').oninput=function(){
			location.hash=`#${path}|${timeline[this.value]}`;
		};
		window.onhashchange();
	});
};

render=()=>{
	var time=timeline[$('#q').value];
	$('#time').innerText=time;
	$('#path').innerHTML=path.split('/').map((v,i,a)=>
			`<a href="#${a.slice(0,i+1).join('/')}|${time}">${decodeURIComponent(v)}</a>`
			).join('/');
	if(pass){
		// show tar-btn
		$('#tar-lnk').style.display='none';
		$('#tar-btn').style.display='';
	} else {
		// show tar-lnk
		$('#tar-btn').style.display='none';
		$('#tar-lnk').style.display='';
		$('#tar-lnk').href=`/cgi-bin/api.sh?|tar|${path}|${time}`;
	}
	api(`ls|${path}|${time}`).then(a=>{
		$('#here').innerHTML=(
					// add dirs first
					Object.keys(dirtree[path].children).filter(a=>{
						var child=dirtree[`${path}/${a}`];
						return child.created <= time && child.deleted>time;
					}).map(a=>`<a class="dir" href="#${path}/${a}|${time}">${a}</a>`).join('')
				)+(($('#file_show').checked)?(
						a.split('\n').filter(a=>!!a).map(a=>a.split('|')).map(a=>
							`<a class="file" href="#${path}|${time}|${a[0]}">${a[0]}</a>`
						).join('')
					):pass?(
						a.split('\n').filter(a=>!!a).map(a=>a.split('|')).map(a=>
							`<a class="file" href="#${path}|${time}|${a[0]}|${a[1]}">${a[0]}</a>`
						).join('')
				       ):(
						a.split('\n').filter(a=>!!a).map(a=>a.split('|')).map(a=>
							`<a class="file" href="/cgi-bin/api.sh?|get|${path}|${a[1]}|${a[0]}">${a[0]}</a>`
						).join('')
				));
	});
	if(file){
		if(file_time){
			getFile(`get|${path}|${file_time}|${file}`,file);
			if(window.history.length>1){
				window.history.back();
			} else {
				var base_href=location.href.replace(/#.*/,'');
				location.replace(`${base_href}#${path}|${time}`);
			}
		} else {
			fileDetails(file);
		}
	} else {
		$('#file_group').style.display='none';
	}
}

fileDetails=(name)=>{
	var freq={0:'Сейчас',1:'Месяц',5:'Неделя',30:'День',720:'Час',8640:'Часто'};
	api(`ll|${path}||${name}`).then(a=>{
		$('#file_list').innerHTML=a.split('\n').filter(a=>!!a).map(a=>a.split('|')).map(a=>
				`<tr><td><a href="#${path}|${time}|${name}|${a[0]}">${name}</a></td><td>${a[0]}</td><td>${a[1].startsWith('9999')?' ':a[1]}</td><td>${freq[a[2]]}</td></tr>`
				).join('');
		$('#file_group').style.display='';
	});
}
closeFileDetails=()=>{
	var time=timeline[$('#q').value];
	location.hash=`#${path}|${time}`;
}

getFile=(params, name)=>{
	api(params, true).then(b=>{
		// createAndDownloadBlobFile(arrayBuffer, 'testName');
		// from https://medium.com/@riccardopolacci/download-file-in-javascript-from-bytea-6a0c5bb3bbdb
		var link = document.createElement('a');
		var url = URL.createObjectURL(b);
		link.setAttribute('href', url);
		link.setAttribute('download', name);
		link.style.visibility = 'hidden';
		document.body.appendChild(link);
		link.click();
		document.body.removeChild(link);
	});
}

$('#file_group').onclick=$('#file_close').onclick=closeFileDetails;

$('#file_dl').onclick=$('#file_show').onclick=render;

$('#tar-btn').onclick=()=>getFile(`tar|${path}|${time}`,path.replace(/.*[\/]/,'')+'.tar');

// INIT
fillBackups();

// resize style
resizeTimer=-1;
resizeFunction=()=>{
	var margin=$('.bar').offsetTop;
	document.body.style.height='calc(100% - '+2*margin+'px)';
	$('#here').style.height=document.body.offsetHeight-$('#here').offsetTop-2*margin+'px';
	resizeTimer=-1;
};
window.onresize=()=>{
	if(resizeTimer!=-1) clearTimeout(resizeTimer);
	resizeTimer=setTimeout(resizeFunction,300);
};
resizeFunction();
