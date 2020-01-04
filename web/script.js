$=(x)=>document.querySelector(x);

api=async(params, returnBlob)=>{
	var a=await fetch(`/cgi-bin/api.sh?${pass}|${params}`);
	if(a.status==403){
		// ask for a password
		if(pass=prompt('[username] password',pass)){
			// retry with a new password
			return await api(params, returnBlob);
		} else {
			throw "No password";
		}
	} else if(returnBlob) {
		return await a.blob();
	} else {
		return await a.text();
	}
}

mode='unknown';
root_dirs=[];
timeline=[];
ticks=[]; // ticks on the timeline input - mark first {weekly,daily,hourly} backup
pass='';
path='./';
time='current';
file='';

ls=async(dir,at)=>{
	// TODO: set timeout to clear everything after
	var a=await api(`ls|${dir}|${at}`)
	$('#here').innerHTML=a.split('\n').filter(a=>!!a).map(a=>a.split('|')).map(a=>
			//a=['filename','type','created~deleted']
			(a[1]=='d')?(`<a class="dir" href="#${dir}${a[0]}/|${at}">${a[0]}</a>`):
				($('#file_show').checked)?(
					// show info about file
					`<a class="file" href="#${dir}|${at}|${a[0]}">${a[0]}</a>`
					):pass?(
						// downlad passworded file
						`<a class="file" href="#${dir}|${at}|${a[0]}|${a[1]}">${a[0]}</a>`
					       ):(
						       // downlad file directly
						       `<a class="file" href="/cgi-bin/api.sh?|get|${dir}|${a[1]}|${a[0]}">${a[0]}</a>`
						 )).join('');
	if(pass){
		// show tar-btn
		$('#tar-lnk').style.display='none';
		$('#tar-btn').style.display='';
	} else {
		// show tar-lnk
		$('#tar-btn').style.display='none';
		$('#tar-lnk').style.display='';
		$('#tar-lnk').href=`/cgi-bin/api.sh?|tar|${path}|${at}`;
	}
}

// from https://stackoverflow.com/a/21822316
function sortedIndex(array, value) {
    var low = 0,
        high = array.length;

    while (low < high) {
        var mid = (low + high) >>> 1;
        if (array[mid] < value) low = mid + 1;
        else high = mid;
    }
    return low;
}
function sortedInsert(array, value) {
	var pos = sortedIndex(array, value);
	if(array[pos] != value) {
		array.splice(pos, 0, value);
	}
}

// helper function for the next one
fillFreqtimes=(freqtimes, ticks, date, n, inc, weekly)=>{
	// freqtimes and ticks are arrays to be edited;
	// date is 1-based array of int (year, month, day, hour, minute, second)
	// n is index in that array - what choud be increased
	// inc is by how much
	// weekly is a special flag to search for monday first
	// so for weekly backups (every monday):
	// n=3 (`day` field in 1-based `date` array)
	// inc=7 (we check every 7th day)
	// weekly=true
	date[2]--; // decrease month since they are 0-based
	date[n]+=inc; // start with second backup, since first one might be partial
	if(weekly){
		while(true){
			var day=new Date(Date.UTC(date[1],date[2],date[3]));
			if(day.getDay()==1) break;
			date[3]++;
		}
	}
	var day=new Date(Date.UTC(date[1],date[2],(n>2)?date[3]:1, (n>3)?date[4]:0,(n>4)?date[5]:0));
	var now=new Date();
	var now=new Date(Date.UTC(now.getFullYear(),now.getMonth(),now.getDate(), now.getHours(),now.getMinutes()));
	ticks.push(day.toISOString().slice(0, 19).replace('T',' '));
	while(true){
		// TODO: try modifying a single Date instance instead of creating a new one
		var day=new Date(Date.UTC(date[1],date[2],(n>2)?date[3]:1, (n>3)?date[4]:0,(n>4)?date[5]:0));
		if(day>now) break;
		freqtimes[day.toISOString().slice(0, 19).replace('T',' ')]=1;
		date[n]+=inc;
	}
}

timeline_cache={};
ticks_cache={};

fetchTimeline=async(dir)=>{
	var a=await api(`timeline|${dir}`);
	var data=a.split('\n').filter(a=>!!a);
	var idx=data.indexOf('===');
	var changes=data.slice(0,idx);
	ticks=[];
	var freqtimes={}; // all possible times received via 
	data.slice(idx+1).map(a=>a.split('|')).forEach(a=>{
		var e=a[1].match(/^([0-9]*)-([0-9]*)-([0-9]*) ([0-9]*):([0-9]*):([0-9]*)$/);
		var d=e.map(a=>parseInt(a));
		switch(a[0]){
			case '1':
				// add 1st of every month (field 2)
				fillFreqtimes(freqtimes,ticks,d, 2,1);
				break;
			case '5':
				// add evey 7th day (field 3) starting from Monday
				fillFreqtimes(freqtimes,ticks,d, 3,7,true);
				break;
			case '30':
				// add evey day (field 3) starting from provided date
				fillFreqtimes(freqtimes,ticks,d, 3,1);
				break;
			case '720':
				// add evey hour (field 4)
				fillFreqtimes(freqtimes,ticks,d, 4,1);
				break;
			case '8640':
				// add evey 5th minute (field 5)
				fillFreqtimes(freqtimes,ticks,d, 5,5);
				break;
			default:
				// add evey minute (field 5)
				fillFreqtimes(freqtimes,ticks,d, 5,1);
				break;
		} // switch
	});
	var ft=Object.keys(freqtimes).sort();
	var j=0;
	// TODO: check that we're still in this dir
	timeline=[];
	for(var i=0;i<ft.length;i++){
		if(changes[j]>ft[i]){
			continue;
		}
		timeline.push(ft[i]);
		while(j<changes.length && changes[j]<=ft[i]){
			j++;
		}
		if(j==changes.length){
			break;
		}
	}
	timeline.push('current');
	timeline_cache[dir]=timeline;
	ticks_cache[dir]=ticks;
}

// fill timeline input (top right corner) and timeline global var
fillTimeline=async(dir, current)=>{
	// TODO: timeline_timer
	timeline=timeline_cache[dir];
	ticks=ticks_cache[dir];
	if(!timeline){
		await fetchTimeline(dir);
	}
	// TODO: this modifies timeline in cache, which is not nice
	sortedInsert(timeline, current);
	ticks.push(timeline[timeline.length-1]);
	$('#marks').innerHTML=ticks.map(a=>timeline.indexOf(a)).filter(a=>a!=-1).map(a=>`<option value="${a}">`).join('\n');
	$('#q').max=timeline.length-1;
	$('#q').value=timeline.indexOf(current);
	$('#q').oninput=function(){
		location.hash=`#${path}|${timeline[this.value]}`;
	};
};


render=async()=>{
	$('#time').innerText=time;
	$('#path').innerHTML=path.split('/').map((v,i,a)=>
			`<a href="#${a.slice(0,i+1).join('/')}/|${time}">${decodeURIComponent(v)}</a>`
			).join('/');

	await ls(path,time);
	/*await*/ fillTimeline(path,time);
	if(!file){
		$('#file_group').style.display='none';
		return;
	}
	if(!file_time){
		fileDetails(file);
		return;
	}
	// download file
	getFile(`get|${dir}|${file_time}|${file}`,file);
	if(window.history.length>1){
		window.history.back();
	} else {
		var base_href=location.href.replace(/#.*/,'');
		location.replace(`${base_href}#${dir}|${time}`);
	}
}

fileDetails=(name)=>{
	var freq={0:'Сейчас',1:'Месяц',5:'Неделя',30:'День',720:'Час',8640:'Часто'};
	api(`ll|${path}||${name}`).then(a=>{
			a=a.split('\n').filter(a=>!!a);
			var sep=a.shift();
			var now=a.shift();
				// a[0]=created, a[1]=deleted, a[2]=freq
		$('#file_list').innerHTML=pass?(
				a.sort().map(a=>a.split('|')).map(a=>
				`<tr><td><a href="#${path}|${time}|${name}|${a[0]}${sep}${a[1]}">${name}</a></td><td>${a[0]}</td><td>${a[1]==now?' ':a[1]}</td><td>${freq[a[2]]}</td></tr>`
				).join('')
			):(
				a.sort().map(a=>a.split('|')).map(a=>
				`<tr><td><a href="/cgi-bin/api.sh?|get|${path}|${a[0]}${sep}${a[1]}|${name}">${name}</a></td><td>${a[0]}</td><td>${a[1]==now?' ':a[1]}</td><td>${freq[a[2]]}</td></tr>`
				).join('')
			);
		$('#file_group').style.display='';
	});
}
closeFileDetails=function(e){
	//ensure that this event fires only when clicking close button or shade
	if( e.target !== this) return;
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

window.onhashchange=()=>{
	// #dir|dir-date|file|file-date
	var loc=decodeURIComponent(location.hash.slice(1)).split('|');
	path=loc[0]||'./';
	time=loc[1]||'current';
	file=loc[2]||'';
	file_time=loc[3]||'';
	render();
}

// INIT
// init();
window.onhashchange();


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


