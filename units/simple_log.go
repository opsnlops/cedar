package units

import (
	"fmt"
	"strings"
	"time"

	"github.com/mongodb/amboy"
	"github.com/mongodb/amboy/dependency"
	"github.com/mongodb/amboy/job"
	"github.com/mongodb/amboy/registry"
	"github.com/mongodb/curator/sthree"
	"github.com/pkg/errors"
	"github.com/tychoish/grip"
	"github.com/tychoish/grip/message"
	"github.com/tychoish/sink"
	"github.com/tychoish/sink/model/log"
)

const (
	saveSimpleLogJobName = "save-simple-log"
)

func init() {
	registry.AddJobType(saveSimpleLogJobName, func() amboy.Job {
		return saveSimpleLogToDBJobFactory()
	})
}

type saveSimpleLogToDBJob struct {
	Timestamp time.Time `bson:"ts" json:"ts" yaml:"timestamp"`
	Content   []string  `bson:"content" json:"content" yaml:"content"`
	Increment int       `bson:"i" json:"inc" yaml:"increment"`
	LogID     string    `bson:"logID" json:"logID" yaml:"logID"`
	*job.Base `bson:"metadata" json:"metadata" yaml:"metadata"`
}

func saveSimpleLogToDBJobFactory() amboy.Job {
	j := &saveSimpleLogToDBJob{
		Base: &job.Base{
			JobType: amboy.JobType{
				Name:    saveSimpleLogJobName,
				Version: 1,
			},
		},
	}
	j.SetDependency(dependency.NewAlways())

	return j
}

func MakeSaveSimpleLogJob(logID, content string, ts time.Time, inc int) amboy.Job {
	j := saveSimpleLogToDBJobFactory().(*saveSimpleLogToDBJob)
	j.SetID(fmt.Sprintf("%s-%s-%d", j.Type().Name, logID, inc))

	j.Timestamp = ts
	j.Content = append(j.Content, content)
	j.LogID = logID
	j.Increment = inc

	return j
}

func (j *saveSimpleLogToDBJob) Run() {
	defer j.MarkComplete()

	conf := sink.GetConf()

	bucket := sthree.GetBucket(conf.BucketName)
	grip.Infoln("got s3 bucket object for:", bucket)

	s3Key := fmt.Sprintf("simple-log/%s.%d", j.LogID, j.Increment)
	err := bucket.Write([]byte(strings.Join(j.Content, "\n")), s3Key, "")
	if err != nil {
		j.AddError(errors.Wrap(err, "problem writing to s3"))
		return
	}

	// clear the content from the job document after saving it.
	j.Content = []string{}

	// in a simple log the log id and the id are different
	doc := &log.Log{
		LogID:       j.LogID,
		Segment:     j.Increment,
		URL:         fmt.Sprintf("http://s3.amazonaws.com/%s/%s", bucket, s3Key),
		NumberLines: -1,
	}

	if err = doc.Insert(); err != nil {
		grip.Warning(message.Fields{"msg": "problem inserting document for log",
			"id":    doc.ID,
			"error": err,
			"doc":   fmt.Sprintf("%+v", doc)})
		j.AddError(errors.Wrap(err, "problem inserting record for document"))
		return
	}

	q, err := sink.GetQueue()
	if err != nil {
		j.AddError(errors.Wrap(err, "problem fetching queue"))
		return
	}
	grip.Debug(q)
	grip.Alert("would submit multiple jobs to trigger post processing, if needed")

	// TODO talk about the structuar of the parser interface, it causes a panic that I don't quite understand yet

	// parserOpts := parser.ParserOptions{
	// 	ID:      doc.ID,
	// 	Content: j.Content,
	// }

	// parsers := []parser.Parser{&parser.SimpleParser{}}
	// for _, p := range parsers {
	// 	if err := q.Put(MakeParserJob(p, parserOpts)); err != nil {
	// 		j.AddError(err)
	// 		return
	// 	}
	// }
	// TODO: make this a loop for putting all jobs for all parsers

	// as an intermediary we could just do a lot of log parsing
	// here. to start with and then move that out to other jobs
	// later.
	//
	// eventually we'll want this to be in seperate jobs because
	// we'll want to add additional parsers and be able to
	// idempotently update our records/metadata for each log.
}
