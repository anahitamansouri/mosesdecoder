#include <cstdlib>
#include <iostream>
#include <algorithm>
#include <string>
#include <boost/timer/timer.hpp>

#include "nmt.h"
#include "mblas/matrix.h"
#include "common/model.h"
#include "common/encoder.h"
#include "common/decoder.h"
#include "common/vocab.h"
#include "common/states.h"


using namespace mblas;

NMT::NMT(const boost::shared_ptr<Weights> model,
         const boost::shared_ptr<Vocab> src,
         const boost::shared_ptr<Vocab> trg)
  : debug_(false), w_(model), src_(src), trg_(trg),
    encoder_(new Encoder(*w_)), decoder_(new Decoder(*w_)),
    states_(new States()), firstWord_(true)
  {
    for(size_t i = 0; i < trg_->size(); ++i)
      filteredId_.push_back(i);
  }
  
void NMT::PrintState(StateInfoPtr ptr) {
  std::cerr << *ptr << std::endl;
}

size_t NMT::GetDevices(size_t maxDevices) {
  int num_gpus = 0;   // number of CUDA GPUs
  cudaGetDeviceCount(&num_gpus);
  std::cerr << "Number of CUDA devices: " << num_gpus << std::endl;
  
  for (int i = 0; i < num_gpus; i++) {
      cudaDeviceProp dprop;
      cudaGetDeviceProperties(&dprop, i);
      std::cerr << i << ": " << dprop.name << std::endl;
  }
  return (size_t)std::min(num_gpus, (int)maxDevices);
}

void NMT::SetDevice() {
  std::cerr << "Setting device " << w_->GetDevice() << std::endl;
  cudaSetDevice(w_->GetDevice());
  CublasHandler::StaticHandle();
}


size_t NMT::GetDevice() {
  std::cerr << "Returning device " << w_->GetDevice() << std::endl;
  return w_->GetDevice();
}

void NMT::ClearStates() { 
  states_->Clear();
}

boost::shared_ptr<Weights> NMT::NewModel(const std::string& path, size_t device) {
  std::cerr << "Got device " << device << std::endl;
  cudaSetDevice(device);
  CublasHandler::StaticHandle();
  boost::shared_ptr<Weights> weights(new Weights(path, device));
  return weights;
}

boost::shared_ptr<Vocab> NMT::NewVocab(const std::string& path) {
  boost::shared_ptr<Vocab> vocab(new Vocab(path));
  return vocab;
}

void NMT::CalcSourceContext(const std::vector<std::string>& s) {  
  std::vector<size_t> words(s.size());
  std::transform(s.begin(), s.end(), words.begin(),
                 [&](const std::string& w) { return (*src_)[w]; });
  words.push_back((*src_)["</s>"]);
  
  SourceContext_.reset(new Matrix());
  Matrix& SC = *boost::static_pointer_cast<Matrix>(SourceContext_);
  encoder_->GetContext(words, SC);
}

StateInfoPtr NMT::EmptyState() {
  Matrix& SC = *boost::static_pointer_cast<Matrix>(SourceContext_);
  Matrix Empty;
  decoder_->EmptyState(Empty, SC, 1);
  std::vector<StateInfoPtr> infos;
  states_->SaveStates(infos, Empty);
  return infos.back();
}

void NMT::FilterTargetVocab(const std::set<std::string>& filter) {
  filteredId_.clear();
  filteredId_.resize(trg_->size(), 1); // set all to UNK
  
  std::vector<size_t> numericFilter;
  size_t k = 0;
  for(auto& s : filter) {
    size_t id = (*trg_)[s];
    numericFilter.push_back(id);
    filteredId_[id] = k;
    k++;
  }
  // eol
  numericFilter.push_back(numericFilter.size());
  decoder_->Filter(numericFilter);
}

void NMT::MakeStep(
  const std::vector<std::string>& nextWords,
  const std::vector<std::string>& lastWords,
  std::vector<StateInfoPtr>& inputStates,
  std::vector<double>& logProbs,
  std::vector<StateInfoPtr>& outputStates,
  std::vector<bool>& unks) {
  
  Matrix& sourceContext = *boost::static_pointer_cast<Matrix>(SourceContext_);
  
  Matrix lastEmbeddings;
  if(firstWord_) {
    firstWord_ = false;
    // Only empty state in state cache, so this is the first word
    decoder_->EmptyEmbedding(lastEmbeddings, lastWords.size());
  }
  else {
    // Not the first word
    std::vector<size_t> lastIds(lastWords.size());
    std::transform(lastWords.begin(), lastWords.end(), lastIds.begin(),
                   [&](const std::string& w) { return (*trg_)[w]; });
    decoder_->Lookup(lastEmbeddings, lastIds);
  }
  
  Matrix nextEmbeddings;
  std::vector<size_t> nextIds(nextWords.size());
  std::transform(nextWords.begin(), nextWords.end(), nextIds.begin(),
                 [&](const std::string& w) { return (*trg_)[w]; });
  decoder_->Lookup(nextEmbeddings, nextIds);
  for(auto id : nextIds) {
    if(id != 1)
      unks.push_back(true);
    else
      unks.push_back(false);
  }
  
  Matrix prevStates;
  states_->ConstructStates(prevStates, inputStates);

  Matrix probs;
  Matrix alignedSourceContext;
  decoder_->GetProbs(probs, alignedSourceContext,
                     prevStates, lastEmbeddings, sourceContext);  
  
  for(size_t i = 0; i < nextIds.size(); ++i) {
    float p = probs(i, filteredId_[nextIds[i]]);
    //float p = probs(i, nextIds[i]);
    logProbs.push_back(log(p));
  }
                    
  Matrix nextStates;
  decoder_->GetNextState(nextStates, nextEmbeddings,
                        prevStates, alignedSourceContext);
  states_->SaveStates(outputStates, nextStates);
  
}
