package model

import (
	"github.com/evergreen-ci/sink"
	"github.com/evergreen-ci/sink/bsonutil"
	"github.com/pkg/errors"
	"github.com/tychoish/anser/db"
	"gopkg.in/mgo.v2/bson"
)

const logSegmentsCollection = "simple.log.segments"

type LogSegment struct {
	// common log information
	ID      string `bson:"_id"`
	LogID   string `bson:"log_id"`
	URL     string `bson:"url"`
	Segment int    `bson:"seg"`
	Bucket  string `bson:"bucket"`
	KeyName string `bson:"key"`

	// parsed out information
	Metrics LogMetrics `bson:"metrics"`

	Metadata `bson:"metadata"`

	// internal fields used by methods:
	populated bool
	env       sink.Environment
}

var (
	logSegmentDocumentIDKey = bsonutil.MustHaveTag(LogSegment{}, "ID")
	logSegmentLogIDKey      = bsonutil.MustHaveTag(LogSegment{}, "LogID")
	logSegmentURLKey        = bsonutil.MustHaveTag(LogSegment{}, "URL")
	logSegmentKeyNameKey    = bsonutil.MustHaveTag(LogSegment{}, "KeyName")
	logSegmentSegmentIDKey  = bsonutil.MustHaveTag(LogSegment{}, "Segment")
	logSegmentMetricsKey    = bsonutil.MustHaveTag(LogSegment{}, "Metrics")
	logSegmentMetadataKey   = bsonutil.MustHaveTag(LogSegment{}, "Metadata")
)

type LogMetrics struct {
	NumberLines       int            `bson:"lines"`
	UniqueLetters     int            `bson:"letters"`
	LetterFrequencies map[string]int `bson:"frequencies"`
}

var (
	logMetricsNumberLinesKey     = bsonutil.MustHaveTag(LogMetrics{}, "NumberLines")
	logMetricsUniqueLettersKey   = bsonutil.MustHaveTag(LogMetrics{}, "UniqueLetters")
	logMetricsLetterFrequencyKey = bsonutil.MustHaveTag(LogMetrics{}, "LetterFrequencies")
)

func (l *LogSegment) Setup(e sink.Environment) { l.env = e }
func (l *LogSegment) IsNil() bool              { return l.populated }

func (l *LogSegment) Insert() error {
	if l.ID == "" {
		l.ID = string(bson.NewObjectId())
	}

	conf, session, err := sink.GetSessionWithConfig(l.env)
	if err != nil {
		return errors.WithStack(err)
	}
	defer session.Close()

	return errors.WithStack(session.DB(conf.DatabaseName).C(depNodeCollection).Insert(l))
}

func (l *LogSegment) Find(logID string, segment int) error {
	conf, session, err := sink.GetSessionWithConfig(l.env)
	if err != nil {
		return errors.WithStack(err)
	}
	defer session.Close()

	filter := map[string]interface{}{
		logSegmentLogIDKey: logID,
	}

	if segment >= 0 {
		filter[logSegmentSegmentIDKey] = segment
	}

	l.populated = false
	err = session.DB(conf.DatabaseName).C(logSegmentsCollection).Find(filter).One(l)
	if db.ResultsNotFound(err) {
		return nil
	}

	if err != nil {
		return errors.Wrapf(err, "problem running log query %+v", filter)
	}

	l.populated = true

	return nil
}

func (l *LogSegment) Remove() error {
	conf, session, err := sink.GetSessionWithConfig(l.env)
	if err != nil {
		return errors.WithStack(err)
	}
	defer session.Close()

	return errors.WithStack(session.DB(conf.DatabaseName).C(logSegmentsCollection).RemoveId(l.ID))
}

func (l *LogSegment) Save() error {
	conf, session, err := sink.GetSessionWithConfig(l.env)
	if err != nil {
		return errors.WithStack(err)
	}
	defer session.Close()

	filter := l.Metadata.IsolatedUpdateQuery(logSegmentMetadataKey, l.ID)
	err = errors.WithStack(session.DB(conf.DatabaseName).C(logSegmentsCollection).Update(filter, l))
	return l.Metadata.Handle(err)
}

///////////////////////////////////
//
// slice type queries that return a multiple segments

type LogSegments struct {
	logs      []LogSegment
	populated bool
	env       sink.Environment
}

func (l *LogSegments) Setup(e sink.Environment) { l.env = e }
func (l *LogSegments) IsNil() bool              { return l.populated }
func (l *LogSegments) Slice() []LogSegment      { return l.logs }

func (l *LogSegments) Find(logID string, sorted bool) error {
	conf, session, err := sink.GetSessionWithConfig(l.env)
	if err != nil {
		return errors.WithStack(err)
	}
	defer session.Close()

	filter := map[string]interface{}{logSegmentLogIDKey: logID}
	query := session.DB(conf.DatabaseName).C(logSegmentsCollection).Find(filter)

	if sorted {
		query = query.Sort("-" + logSegmentSegmentIDKey)
	}

	l.populated = false
	err = query.All(l.logs)
	if db.ResultsNotFound(err) {
		return nil
	}

	if err != nil {
		return errors.Wrapf(err, "problem running log query %+v", query)
	}

	l.populated = true

	return nil
}
