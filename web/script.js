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

pad=(n)=>(n<10)?'0'+n:n;
date2str=(day)=>day.getFullYear()+'-'+pad(day.getMonth()+1)+'-'+pad(day.getDate())+' '+pad(day.getHours())+':'+pad(day.getMinutes())+':'+pad(day.getSeconds());

// helper function for the next one
fillFreqtimes=(freqtimes, ticks, date, n, inc)=>{
	// freqtimes and ticks are arrays to be edited;
	// ~~~ date is 1-based array of int (year, month, day, hour, minute, second)
	// date is Date
	// n is index in that array - what choud be increased
	// inc is by how much
	// weekly is a special flag to search for monday first
	// so for weekly backups (every monday):
	// n=3 (`day` field in 1-based `date` array)
	// inc=7 (we check every 7th day)
	// weekly=true
	date[2]--; // decrease month since they are 0-based
	date[n]+=inc; // start with second backup, since first one might be partial
	var day=new Date(Date.UTC(date[1],date[2],(n>2)?date[3]:1, (n>3)?date[4]:0,(n>4)?date[5]:0));
	var now=new Date();
	var now=new Date(Date.UTC(now.getFullYear(),now.getMonth(),now.getDate(), now.getHours(),now.getMinutes()));
	ticks.push(day.toISOString().slice(0, 19).replace('T',' '));
	while(true){
		// TODO: try modifying a single Date instance instead of creating a new one
		var day=new Date(Date.UTC(date[1],date[2],(n>2)?date[3]:1, (n>3)?date[4]:0,(n>4)?date[5]:0));
		if(day>now) break;
		var a=day.getFullYear()+'-'+pad(day.getMonth()+1)+'-'+pad(day.getDay())+' '+pad(day.getHours())+':'+pad(day.getMinutes())+':'+pad(day.getSeconds());
		freqtimes[a]=1;
		date[n]+=inc;
	}
}

timeline_cache={true:{},false:{}};
ticks_cache={true:{},false:{}};

fetchTimeline=async(dir,all)=>{
	var a=await api(`timeline|${dir}`);
	var data=a.split('\n').filter(a=>!!a);
	var idx=data.indexOf('===');
	var changes=data.slice(0,idx);
	ticks=[];
	timeline=[];
	var freqtimes={}; // all possible times received via 
	var freqs=data.slice(idx+1).map(a=>a.split('|'));
	var prop={'1':'Month', '5':'Date', '30':'Date','720':'Hours','8640':'Minutes','43800':'Minutes'};
	var step={'1':1,       '5':7,      '30':1,     '720':1,      '8640':5,        '43800':1};
	for(var i=0; i<freqs.length; i++) {
		var d=new Date(freqs[i][1]);
		// Now we need to rewind `d` to be _next_ good day. For example,
		// if `d` is Jan 12th, and freq==1 (monthly), wee need to find
		// Feb 1st. However, if `d` is Jan 1st - we need to find Feb
		// 1st, too - because "oldest backup might be incomplete". For
		// this, we first find matching day by rewinding backwards (set
		// Jan 1st both for Jan 12th and Jan 1st - that's trivial - just
		// `d.setDate(1)`), and then move forward to next month
		// (`d.setMonth(d.getMonth()+1)`).
		// Part 1: rewinding backwards
		switch(freqs[i][0]){
			// note that this switch is without breaks, so following
			// commands are executed for all preceding cases
			case '1': //monthly
				d.setDate(1);
			case '5': //weekly
			case '30': //daily
				d.setHours(0);
			case '720': //hourly
				d.setMinutes(0);
			case '8640': //5-minutes
			default: //every minute
				d.setSeconds(0);
				d.setMilliseconds(0);
		} // switch
		if(freqs[i][0]=='5'){
			if(d.getDay()>1){
				d.setDate(d.getDate()-d.getDay()+1);
			} else if(d.getDay()==0){
				d.setDate(d.getDate()-7+1);
			}
		}
		if(freqs[i][0]=='8640'){
			d.setMinutes(d.getMinutes()-d.getMinutes()%5);
		}
		// Part 2: Move 1 step forward
		if(!all){
			// console.log(freqs[i][0], 'DOING part 2');
			d['set'+prop[freqs[i][0]]](d['get'+prop[freqs[i][0]]]()+step[freqs[i][0]]);
			// Explanation of the line above:
			// freqs[i][0] is current freq
			// prop[freqs[i][0]] is the property which we're changing ('Month')
			// step[freqs[i][0]] is by how much (usually 1)
			// 'set'+prop[freqs[i][0]] is this property setter
			// So above line is:
			// d['set'+'Month'](d['get'+'Month']()+1)
		}
		freqs[i][1]=date2str(d);
		freqs[i][2]=d;
	}
	// freqs is array of [freq, 'date', Date]
	// Add a "dummy" freq with limiting date for the last freq
	freqs.push([0,changes[changes.length-1]]);
	var must_sort=false;
	var j=0;
	// Now, loop through non-"dummy" freqs and fill result array
	for(var i=0; i<freqs.length-1; i++) {
		if(i==0 || freqs[i][1]<freqs[i-1][1]){
			var j=0;
			if(timeline.length>0){
				must_sort=true;
			}
		}
		var d=freqs[i][2];
		ticks.push(date2str(d));
		while(true){
			var str_day=date2str(d);
			if(str_day>=freqs[i+1][1]) break;
			if(j==changes.length) break;
			if(changes[j]<=str_day) timeline.push(str_day);
			while(j<changes.length && changes[j]<=str_day) j++;
			d['set'+prop[freqs[i][0]]](d['get'+prop[freqs[i][0]]]()+step[freqs[i][0]]);
		}
	}
	// TODO: check that we're still in this dir
	if(must_sort){
		timeline.sort();
	}
	timeline.push('current');
	timeline_cache[all][dir]=timeline;
	ticks_cache[all][dir]=ticks;
}

// fill timeline input (top right corner) and timeline global var
fillTimeline=async(dir, current, show_all)=>{
	// TODO: timeline_timer
	timeline=timeline_cache[show_all][dir];
	ticks=ticks_cache[show_all][dir];
	if(!timeline){
		await fetchTimeline(dir,show_all);
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
	$('#show_questionable_times').onclick=function(){
		fillTimeline(path,time,$('#show_questionable_times').checked);
	};
};


render=async()=>{
	$('#time').innerText=time;
	$('#path').innerHTML=path.split('/').map((v,i,a)=>
			`<a href="#${a.slice(0,i+1).join('/')}/|${time}">${decodeURIComponent(v)}</a>`
			).join('/');

	await ls(path,time);
	/*await*/ fillTimeline(path,time,$('#show_questionable_times').checked);
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
api('init');
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


